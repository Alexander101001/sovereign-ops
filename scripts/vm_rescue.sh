#!/data/data/com.termux/files/usr/bin/sh
# Idempotent rescue kit for the 1GB micro VM (fed via ssh 'bash -s')
if ! swapon --show | grep -q /swapfile; then
  sudo systemctl disable --now dnf-makecache.timer dnf-makecache.service 2>/dev/null
  sudo dnf clean all -q 2>/dev/null
  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile 2>/dev/null && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  echo RESCUE_APPLIED
else
  echo RESCUE_ALREADY_OK
fi
