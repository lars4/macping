# macping

Ask your Mac over Telegram whether it is **online** and **plugged in** – and where it is.

A tiny macOS LaunchAgent written in plain bash. No Homebrew, no Python, no
open ports: the Mac polls a Telegram bot, so it works behind any NAT or
firewall.

```
You:    status
Bot:    ✅ Online
        🔌 On AC power
        100%; charged
        ⚙️ CPU 12% · RAM 61% (avg of last 10 min)
        Uptime: 2 days, 4:12
        Time: 2026-01-15 21:14:03

You:    /location
Bot:    📍 Location via Wi-Fi (±35 m)
        https://maps.google.com/?q=47.050000,8.300000
        [map pin]
```

## Features

- **Status on demand** – send any message to get power source, battery level and charging state, mean CPU and RAM usage over the last 10 minutes, uptime and local time.
- **Location on demand** – `/location` returns a map pin. Uses CoreLocation (Wi-Fi positioning, typically 10–50 m) and falls back to IP geolocation (city level).
- **Tidy chat** – previous replies and your request are deleted automatically, so the chat only ever shows the latest answer.
- **Private** – only reacts to messages from your own chat ID; everything else is ignored.
- **Zero dependencies** – uses only tools that ship with macOS (`bash`, `curl`, `pmset`, `launchctl`). The Xcode Command Line Tools are needed only for the optional precise location.

## Requirements

- macOS (tested on Intel, macOS 15)
- A Telegram account
- Optional, for precise `/location`: Xcode Command Line Tools (`xcode-select --install`)

## Install

1. Create a bot with [@BotFather](https://t.me/BotFather) (`/newbot`) and copy the token.
   Use a **dedicated bot** – see [Limitations](#limitations).
2. Send `/start` to your new bot.
3. Run the installer **without `sudo`**:

   ```bash
   git clone https://github.com/lars4/macping.git
   cd macping
   bash install.sh
   ```

   The installer asks for the token, detects your chat ID, builds the location helper (if the Command Line Tools are present) and starts the agent. You should get a status message within seconds.

4. For precise location, grant access once:

   ```bash
   open ~/.macping/MacPingLoc.app
   ```

   Allow the location prompt. Location Services must be enabled in System Settings.

## Usage

| Message | Reply |
| --- | --- |
| anything (e.g. `status`) | Online/power/battery/uptime status |
| `/location` | Location link and map pin |

No reply means the Mac is off, asleep or offline.

## How it works

```
Telegram  <--long polling (getUpdates)--  macping.sh  (LaunchAgent, KeepAlive)
                                              |
                                              |-- pmset -g batt          power & battery
                                              |-- top / vm_stat          CPU & RAM samples (every 30 s)
                                              |-- MacPingLoc.app         CoreLocation fix
                                              '-- ipinfo.io              IP fallback
```

Files live in `~/.macping/`:

| File | Purpose |
| --- | --- |
| `config` | `BOT_TOKEN` and `CHAT_ID` (mode 600) |
| `macping.sh` | the agent script |
| `MacPingLoc.app` | small Swift helper, ad-hoc signed, runs on demand |
| `msg_ids` | IDs of recent bot messages, used for cleanup |
| `samples` | CPU/RAM samples (every 30 s, last 10 min) for the rolling average |
| `err.log` | stderr of the agent |

The LaunchAgent is `~/Library/LaunchAgents/com.macping.agent.plist`.

## Limitations

- **One consumer per bot.** Telegram delivers updates to a single poller or webhook. If another program already polls the same bot (or a webhook is set), macping and that program will conflict. Use a separate bot for macping.
- **Sleeping Macs don't answer.** A closed MacBook on power normally sleeps. To stay reachable while plugged in, use a clamshell setup or `sudo pmset -c sleep 0`.
- **Starts at login.** LaunchAgents run in a user session, so the Mac must be logged in after a reboot (consider enabling automatic login).
- **Message cleanup is limited to 48 hours** by Telegram. Older messages are left alone.
- **IP geolocation is coarse** and shows the VPN exit if a VPN is active.
- macOS has no GPS; precise location comes from Wi-Fi positioning and needs nearby Wi-Fi networks.

## Troubleshooting

```bash
launchctl list | grep macping      # is the agent loaded?
cat ~/.macping/err.log             # errors from the agent
```

Test token and chat ID directly:

```bash
source ~/.macping/config
curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe"
curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d "chat_id=${CHAT_ID}" -d "text=test"
```

Restart after editing the config:

```bash
launchctl kickstart -k gui/$(id -u)/com.macping.agent
```

| Symptom | Cause / fix |
| --- | --- |
| Bot never replies | Another process polls the bot, or you never sent `/start` to it |
| `CoreLocation failed (ERR not_authorized)` | Run `open ~/.macping/MacPingLoc.app` and allow access |
| `CoreLocation failed (ERR denied)` | Enable it for *MacPingLoc* in Privacy & Security > Location Services |
| `ERR timeout` | No Wi-Fi networks in range (Ethernet-only Mac); IP fallback is used |
| `swiftc` "SDK is not supported by the compiler" | Mismatched Command Line Tools: `sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`, then re-run `install.sh` |

## Security notes

- Only the configured chat ID gets answers. Keep your bot token private; anyone holding it can read messages sent to the bot.
- `/location` sends your Mac's position to Telegram. Only use this on a Mac and Telegram account you control.
- The config file is created with mode 600.

## Uninstall

```bash
bash uninstall.sh
```

## License

MIT – see [LICENSE](LICENSE).
