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
trap 'kill "$SAMPLER" 2>/dev/null' EXIT
trap 'exit 0' TERM INT

# Skip updates that arrived while we were not running.
offset=$(curl -s --max-time 15 "$API/getUpdates?offset=-1" | grep -o '"update_id":[0-9]*' | tail -1 | cut -d: -f2)
offset=$(( ${offset:-0} + 1 ))

cleanup
send "$(status)"

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
    *)                   send "$(status)" ;;
  esac
done
