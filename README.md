# config-monitor 🔍

## Features

- 📁 Monitor multiple directories (/etc, /opt) in parallel
- 🔍 Filter only config files (.conf, .cfg, .ini, .env)
- 👤 Detect which user made the change
- 📸 Auto snapshot/backup on every change
- 📊 Show diff of changed lines
- 📱 Real-time Telegram notifications (+ Email & Slack optional)
- 🚫 Auto blacklist system users & paths (anti false-positive)

## Requirements

```bash
# Install dependencies
sudo apt install inotify-tools auditd
```

## Installation

```bash
# 1. Clone repo
git clone https://github.com/username/config-monitor.git
cd config-monitor

# 2. execute permission
chmod +x config_monitor.sh

# 3. run as root
sudo ./config_monitor.sh
```


## How It Works

```
inotifywait (detect event file)
    ↓
Filter ekstention + blacklist path
    ↓
get_modifier_user (Detect who edit files)
    ↓
show_diff (Line Modify)
    ↓
snapshot_file (Auto Backup)
    ↓
send_telegram (notif real-time)
```

## Example Output Terminal

```
⚠  CONFIG CHANGE DETECTED
┌─────────────────────────────────────────────
│ Time   : 2026-05-24 18:10:15
│ Event  : MODIFY
│ File   : /etc/nginx/nginx.conf
│ Source : /etc
│ User   : rafli (who-recent)
│ SHA256 : 9e94537d8a4bff1b...
└─────────────────────────────────────────────
  │ ── CHANGES ──────────────────────────────────
  │ +workers = 0
  │ -workers = 4
  └─────────────────────────────────────────────
```

## Telegram Notif

```
✏️ CONFIG CHANGE DETECTED

🕐 Time  : 2026-05-24 18:10:15
📋 Event  : MODIFY
📁 File   : /etc/nginx/nginx.conf
📂 Source : /etc
👤 User   : rafli
🔐 SHA256 : 9e94537d8a4bff1b...

📝 Modify:
+workers = 0
-workers = 4
```

## running as a service (opsional)

```bash
# copy service file
sudo cp config-monitor.service /etc/systemd/system/

# Enable dan start
sudo systemctl enable config-monitor
sudo systemctl start config-monitor

sudo systemctl status config-monitor
```


## Note

- should be run as `root`
- user that u want to monitor should be run as a user not (su - user) from root, it will be accurate
- Log saved in `/var/log/config_monitor/`
- Backup snapshot in `/var/backups/config_monitor/`

## License

MIT
