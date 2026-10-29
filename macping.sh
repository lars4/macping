#!/bin/bash
# macping - ask your Mac over Telegram whether it is online and plugged in.
#
# Long-polls a Telegram bot and answers messages from ONE chat (CHAT_ID):
#   /location  -> position via CoreLocation (Wi-Fi), IP geolocation as fallback
#   anything else -> power / battery / uptime status
#
# Config: ~/.macping/config containing BOT_TOKEN=... and CHAT_ID=...

DIR="$HOME/.macping"
CONFIG="${MACPING_CONFIG:-$DIR/config}"
STATE="$DIR/msg_ids"
LOC_APP="$DIR/MacPingLoc.app"
SAMPLES="$DIR/samples"   # CPU/RAM samples for the rolling average
WINDOW=600               # averaging window in seconds (10 min)
INTERVAL=30              # sampling interval in seconds
WATCH_FILE="$DIR/watch"  # exists while watch mode is on
WATCH_INTERVAL=300       # watch-mode ping interval in seconds (5 min)
BEAT_FILE="$DIR/beat"    # epoch of the last watch-mode message
POLL=1                   # how often (seconds) the power source is checked

# Alarm (rings while unplugged in watch mode; volume rises step by step)
ALARM_FLAG="$DIR/alarm"          # exists while the alarm runs (holds the loop's PID)
ALARM_VOL_SAVE="$DIR/alarm.vol"  # your volume/mute state, restored afterwards
ALARM_SOUND="${ALARM_SOUND:-/System/Library/Sounds/Sosumi.aiff}"
AUDIO_OUT="$DIR/audio-out"            # CoreAudio helper: forces the built-in speakers
ALARM_AUDIO_SAVE="$DIR/alarm.audio"   # previous output device, restored afterwards
ALARM_START=10                   # volume (%) during the first step
ALARM_STEP=10                    # volume increase (%) per step
ALARM_STEP_SECONDS=30            # length of one step in seconds
ALARM_MAX=100                    # volume cap (%)

# shellcheck source=/dev/null
source "$CONFIG" || { echo "macping: cannot read $CONFIG" >&2; exit 1; }
: "${BOT_TOKEN:?BOT_TOKEN missing in $CONFIG}" "${CHAT_ID:?CHAT_ID missing in $CONFIG}"
API="https://api.telegram.org/bot${BOT_TOKEN}"

# ---------------------------------------------------------------- Telegram --

get_id() { echo "$1" | grep -o '"message_id":[0-9]*' | head -1 | cut -d: -f2; }

# Remember the IDs of messages we sent so they can be deleted later.
track() { [ -n "$1" ] && echo "$1" >> "$STATE"; }

delete_msg() {
  curl -s --max-time 15 "$API/deleteMessage" \
    -d "chat_id=${CHAT_ID}" -d "message_id=$1" >/dev/null
}

# Delete our previous replies (Telegram only allows this for messages < 48 h old).
cleanup() {
  local id
  [ -f "$STATE" ] || return 0
  while read -r id; do
    [ -n "$id" ] && delete_msg "$id"
  done < "$STATE"
  : > "$STATE"
}

send() {
  local r
  r=$(curl -s --max-time 15 "$API/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=$1")
  track "$(get_id "$r")"
}

# send_location LAT LON [ACCURACY_M]
send_location() {
  local r
  r=$(curl -s --max-time 15 "$API/sendLocation" \
    -d "chat_id=${CHAT_ID}" -d "latitude=$1" -d "longitude=$2" \
    ${3:+-d "horizontal_accuracy=$3"})
  track "$(get_id "$r")"
}

# ------------------------------------------------------------------ Status --

status() {
  local batt src line plug
  batt=$(pmset -g batt)
  src=$(echo "$batt" | head -1 | sed -E "s/.*'(.*)'.*/\1/")
  line=$(echo "$batt" | sed -n 2p | sed -E 's/^[[:space:]]*//' | cut -d';' -f1-2 | sed 's/(id=[0-9]*)//')
  if [ "$src" = "AC Power" ]; then plug="🔌 On AC power"; else plug="🔋 NOT on AC power (battery)"; fi
  printf '✅ Online\n%s\n%s\n%s\nUptime: %s\nTime: %s' \
    "$plug" "$line" "$(usage_avg)" \
    "$(uptime | sed -E 's/.*up ([^,]*(,[^,]*)?),.*user.*/\1/' | sed 's/^ *//')" \
    "$(date '+%Y-%m-%d %H:%M:%S')"
}

# ------------------------------------------------------------ CPU / RAM load --

# One sample: "<epoch> <cpu_percent> <ram_used_percent>" appended to $SAMPLES.
# CPU = 100 - idle (second top sample, i.e. a real 1 s interval).
# RAM = (active + wired + compressed) / total, close to Activity Monitor's "Memory Used".
sample() {
  local cpu vm pgsz used total mem now
  cpu=$(top -l 2 -n 0 -s 1 2>/dev/null | grep '^CPU usage' | tail -1 \
        | sed -E 's/.* ([0-9.]+)% idle.*/\1/' | awk '{printf "%.1f", 100-$1}')
  vm=$(vm_stat)
  pgsz=$(echo "$vm" | head -1 | sed -E 's/.*page size of ([0-9]+) bytes.*/\1/')
  used=$(echo "$vm" | awk -F: -v ps="$pgsz" '
    /Pages active/                  {a=$2+0}
    /Pages wired down/              {w=$2+0}
    /Pages occupied by compressor/  {c=$2+0}
    END {printf "%d", (a+w+c)*ps}')
  total=$(sysctl -n hw.memsize)
  mem=$(awk -v u="$used" -v t="$total" 'BEGIN {printf "%.1f", u/t*100}')
  [ -n "$cpu" ] && [ -n "$mem" ] || return 0
  now=$(date +%s)
  echo "$now $cpu $mem" >> "$SAMPLES"
  # Drop samples older than the window.
  awk -v c=$(( now - WINDOW )) '$1>=c' "$SAMPLES" > "$SAMPLES.tmp" && mv "$SAMPLES.tmp" "$SAMPLES"
}

# Mean CPU and RAM over the last $WINDOW seconds.
usage_avg() {
  local now
  now=$(date +%s)
  [ -f "$SAMPLES" ] || { echo "CPU/RAM: n/a"; return; }
  awk -v c=$(( now - WINDOW )) -v now="$now" '
    $1>=c { n++; cpu+=$2; mem+=$3; if (!f || $1<f) f=$1 }
    END {
      if (n==0) { print "CPU/RAM: n/a"; exit }
      span=int((now-f)/60+0.5); if (span<1) span=1; if (span>10) span=10
      printf "⚙️ CPU %.0f%% · RAM %.0f%% (avg of last %d min)", cpu/n, mem/n, span
    }' "$SAMPLES"
}

set_volume() { osascript -e "set volume output volume $1 without output muted" >/dev/null 2>&1; }

alarm_running() {
  [ -f "$ALARM_FLAG" ] && kill -0 "$(cat "$ALARM_FLAG" 2>/dev/null)" 2>/dev/null
}

# Start the alarm: 10 % for 30 s, then 20 % for 30 s, 30 % ... up to ALARM_MAX.
# It always rings through the built-in speakers (if the audio-out helper exists),
# even when headphones are connected.
alarm_on() {
  local owner=$$ builtin="" orig=""
  alarm_running && return 0
  if [ -x "$AUDIO_OUT" ]; then
    builtin=$("$AUDIO_OUT" builtin 2>/dev/null)
    if [ -n "$builtin" ]; then
      orig=$("$AUDIO_OUT" get 2>/dev/null)
      echo "$orig $builtin $("$AUDIO_OUT" source "$builtin" 2>/dev/null)" > "$ALARM_AUDIO_SAVE"
      "$AUDIO_OUT" set "$builtin" 2>/dev/null
      "$AUDIO_OUT" source "$builtin" ispk 2>/dev/null   # speakers, not the headphone jack
    fi
  fi
  # Remember the current volume/mute state so alarm_off can restore it.
  osascript -e 'set v to get volume settings' \
            -e 'return (output volume of v as text) & " " & (output muted of v as text)' \
            > "$ALARM_VOL_SAVE" 2>/dev/null
  : > "$ALARM_FLAG"
  (
    t0=$(date +%s)
    # Ends when the flag is removed or the agent itself is gone.
    while [ -f "$ALARM_FLAG" ] && kill -0 "$owner" 2>/dev/null; do
      lvl=$(( ALARM_START + ALARM_STEP * ( ( $(date +%s) - t0 ) / ALARM_STEP_SECONDS ) ))
      [ "$lvl" -gt "$ALARM_MAX" ] && lvl=$ALARM_MAX
      if [ -n "$builtin" ]; then   # win back the output if headphones reconnect
        "$AUDIO_OUT" set "$builtin" 2>/dev/null
        "$AUDIO_OUT" source "$builtin" ispk 2>/dev/null
      fi
      set_volume "$lvl"
      afplay "$ALARM_SOUND" 2>/dev/null || sleep 1
    done
  ) &
  echo $! > "$ALARM_FLAG"
}

# Stop the alarm (if any) and restore the previous volume. Safe to call anytime.
alarm_off() {
  local pid vol muted
  if [ -f "$ALARM_FLAG" ]; then
    pid=$(cat "$ALARM_FLAG" 2>/dev/null)
    rm -f "$ALARM_FLAG"
    if [ -n "$pid" ]; then
      pkill -P "$pid" 2>/dev/null
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    fi
  fi
  if [ -f "$ALARM_VOL_SAVE" ]; then
    read -r vol muted < "$ALARM_VOL_SAVE"
    case "$vol" in
      ''|*[!0-9]*) ;;
      *) set_volume "$vol" ;;
    esac
    [ "$muted" = "true" ] && osascript -e 'set volume with output muted' >/dev/null 2>&1
    rm -f "$ALARM_VOL_SAVE"
  fi
  # Give the output back to the headphones / previous device.
  if [ -f "$ALARM_AUDIO_SAVE" ]; then
    local orig builtin src
    read -r orig builtin src < "$ALARM_AUDIO_SAVE"
    if [ -x "$AUDIO_OUT" ]; then
      [ -n "$src" ] && "$AUDIO_OUT" source "$builtin" "$src" 2>/dev/null
      [ -n "$orig" ] && "$AUDIO_OUT" set "$orig" 2>/dev/null
    fi
    rm -f "$ALARM_AUDIO_SAVE"
  fi
  return 0
}

# -------------------------------------------------------------- Watch mode --
#
# /watch  -> alive ping every WATCH_INTERVAL seconds + instant alert when the
#            charger is unplugged. While unplugged an alarm rings with rising
#            volume until you plug in again or send /stop. Every new message
#            replaces the previous ones. The mode survives an agent restart.

power_src() { pmset -g batt | head -1 | sed -E "s/.*'(.*)'.*/\1/"; }

# watch_msg "headline" -> headline + the usual status block
watch_msg() { printf '%s\n%s' "$1" "$(status)"; }

# Replace everything in the chat with a single new message.
replace_with() { cleanup; send "$1"; }

watch_on() {
  : > "$WATCH_FILE"
  date +%s > "$BEAT_FILE"
  replace_with "$(watch_msg "👁 Watch mode ON – ping every $((WATCH_INTERVAL / 60)) min, instant alert if unplugged. Stop with /stop")"
}

watch_off() {
  rm -f "$WATCH_FILE"
  alarm_off
  replace_with "$(watch_msg '👁 Watch mode OFF')"
}

# Runs every POLL seconds in the background watcher (see Main), independent of
# the Telegram long-poll, so plug/unplug is noticed within about a second.
watch_tick() {
  local now src beat
  now=$(date +%s)
  src=$(power_src)
  [ -n "$src" ] || return 0   # pmset hiccup: ignore this tick
  beat=$(cat "$BEAT_FILE" 2>/dev/null); beat=${beat:-$now}
  if [ -f "$WATCH_FILE" ]; then
    if [ "$src" != "$LAST_SRC" ]; then
      if [ "$src" = "AC Power" ]; then
        alarm_off
        replace_with "$(watch_msg '🔌 Plugged in again – alarm silenced')"
      else
        alarm_on
        replace_with "$(watch_msg '🚨 ALERT: Mac was UNPLUGGED – now on battery! 🔊 Alarm ringing (volume rises). Plug in or /stop to silence.')"
      fi
      date +%s > "$BEAT_FILE"
    elif [ $(( now - beat )) -ge "$WATCH_INTERVAL" ]; then
      date +%s > "$BEAT_FILE"
      if alarm_running; then
        replace_with "$(watch_msg '🚨 Still on battery – 🔊 alarm ringing')"
      else
        replace_with "$(watch_msg '💓 Still alive')"
      fi
    fi
  else
    alarm_off   # alarm never outlives watch mode
  fi
  LAST_SRC=$src
}

# ---------------------------------------------------------------- Location --

# Coarse position from the public IP (city level, no permissions needed).
location_ip() {
  local j loc lat lon city region ip org
  j=$(curl -s --max-time 15 https://ipinfo.io/json)
  loc=$(echo "$j"    | grep -o '"loc": *"[^"]*"'    | cut -d'"' -f4)
  city=$(echo "$j"   | grep -o '"city": *"[^"]*"'   | cut -d'"' -f4)
  region=$(echo "$j" | grep -o '"region": *"[^"]*"' | cut -d'"' -f4)
  ip=$(echo "$j"     | grep -o '"ip": *"[^"]*"'     | cut -d'"' -f4)
  org=$(echo "$j"    | grep -o '"org": *"[^"]*"'    | cut -d'"' -f4)
  if [ -z "$loc" ]; then send "❌ Could not determine location"; return; fi
  lat=${loc%,*}; lon=${loc#*,}
  send "📍 ${city}, ${region} (approximate, via IP)
IP: ${ip}
Provider: ${org}
https://maps.google.com/?q=${lat},${lon}"
  send_location "$lat" "$lon"
}

# Precise position via the CoreLocation helper app; falls back to IP.
location() {
  local out="/tmp/macping-loc.txt" r lat lon acc
  if [ -d "$LOC_APP" ]; then
    rm -f "$out"
    open -g -n -W -a "$LOC_APP" --args "$out" 2>/dev/null
    r=$(cat "$out" 2>/dev/null)
    case "$r" in
      ERR*|"")
        send "⚠️ CoreLocation failed (${r:-no response}), using IP location instead" ;;
      *)
        read -r lat lon acc <<< "$r"
        send "📍 Location via Wi-Fi (±${acc} m)
https://maps.google.com/?q=${lat},${lon}"
        send_location "$lat" "$lon" "$acc"
        return ;;
    esac
  fi
  location_ip
}

# -------------------------------------------------------------------- Main --

mkdir -p "$DIR"

# Background sampler for the CPU/RAM average; stops when this script exits.
PARENT=$$
sample
( while kill -0 "$PARENT" 2>/dev/null; do sleep "$INTERVAL"; sample; done ) &
SAMPLER=$!
trap 'kill "$SAMPLER" "$WATCHER" 2>/dev/null; alarm_off' EXIT
trap 'exit 0' TERM INT

# Skip updates that arrived while we were not running.
offset=$(curl -s --max-time 15 "$API/getUpdates?offset=-1" | grep -o '"update_id":[0-9]*' | tail -1 | cut -d: -f2)
offset=$(( ${offset:-0} + 1 ))

cleanup
alarm_off   # clear leftovers of a previous run and restore the volume
LAST_SRC=$(power_src)
date +%s > "$BEAT_FILE"
if [ -f "$WATCH_FILE" ]; then
  if [ "$LAST_SRC" != "AC Power" ]; then
    alarm_on
    send "$(watch_msg '🚨 Watch mode active (restarted) – Mac is on battery! 🔊 Alarm ringing. Plug in or /stop to silence.')"
  else
    send "$(watch_msg '👁 Watch mode active (restarted)')"
  fi
else
  send "$(status)"
fi

# Background watcher: power checks every POLL s (heartbeat, unplug alert, alarm).
# It keeps its own LAST_SRC; it ends together with this script.
( while kill -0 "$PARENT" 2>/dev/null; do watch_tick; sleep "$POLL"; done ) &
WATCHER=$!

while true; do
  resp=$(curl -s --max-time 40 "$API/getUpdates?timeout=30&offset=${offset}")
  if [ -z "$resp" ]; then sleep 10; continue; fi
  last=$(echo "$resp" | grep -o '"update_id":[0-9]*' | tail -1 | cut -d: -f2)
  [ -z "$last" ] && continue
  offset=$((last + 1))

  # Only react to messages from the configured chat.
  echo "$resp" | grep -q "\"chat\":{\"id\":${CHAT_ID}[,}]" || continue

  text=$(echo "$resp" | grep -o '"text":"[^"]*"' | tail -1 | cut -d'"' -f4 | tr '[:upper:]' '[:lower:]')

  # Remove old replies and the incoming request(s), then answer.
  cleanup
  for uid in $(echo "$resp" | grep -o '"message_id":[0-9]*' | cut -d: -f2); do
    delete_msg "$uid"
  done

  case "$text" in
    /location*|location) location ;;
    /watch*)             watch_on ;;
    /stop*)              watch_off ;;
    *)                   send "$(status)" ;;
  esac
done
