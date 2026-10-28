#!/bin/bash
# Full deployment of the money stack onto the Oracle micro VM (run as root via SSH)
set -e
mkdir -p /opt/sovereign/{shopbot,watchers,scripts,state}
cd /opt/sovereign

# 1. Shop bot service (systemd, 24/7)
cat > shopbot/bot.service <<UNIT
[Unit]
Description=Sovereign Shop Bot
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/sovereign/shopbot/bot.py
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
cp shopbot/bot.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now shopbot

# 2. Payment watcher cron (every 15 min)
(crontab -l 2>/dev/null; echo "*/15 * * * * /usr/bin/python3 /opt/sovereign/watchers/payment_watcher.py >> /opt/sovereign/state/watcher.log 2>&1") | crontab -
echo "sovereign stack deployed: shopbot.service + payment watcher cron"
