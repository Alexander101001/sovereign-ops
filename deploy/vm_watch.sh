#!/data/data/com.termux/files/usr/bin/sh
# VM watchdog + A1 auto-launcher — runs every 30min via cron on the phone.
# 1. Checks micro VM SSH health, logs it.
# 2. When VM is healthy (load < 2): pulls diagnostics once, then tries A1 launch FROM the VM
#    (Oracle-internal network path avoids the phone's CannotParseRequest issue).
export PATH="/data/data/com.termux/files/usr/bin:$PATH"
STATE="$HOME/money-projects/money_engine/state/vm_health.log"
LOG="$HOME/money-projects/money_engine/logs/a1_retry.log"
mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")"
TS=$(date '+%Y-%m-%d %H:%M')
KEY="$HOME/.ssh/oci_vm_key"

OUT=$(ssh -i "$KEY" -o ConnectTimeout=12 -o StrictHostKeyChecking=no opc@92.5.18.80 'echo OK; uptime' 2>/dev/null)
if echo "$OUT" | grep -q OK; then
    LOAD=$(echo "$OUT" | grep -oE 'load average: [0-9.]+' | grep -oE '[0-9.]+$')
    echo "$TS REACHABLE load=$LOAD" >> "$STATE"
    # first recovery after an outage → full inventory snapshot (answers "what's on the VM")
    if [ -f "$STATE" ] && ! grep -q REACHABLE "$STATE" 2>/dev/null; then :; fi
    PREV=$(tail -n 2 "$STATE" | head -n 1)
    if echo "$PREV" | grep -q UNREACHABLE; then
        INV="$HOME/money-projects/money_engine/state/vm_inventory_$(date +%Y%m%d_%H%M).txt"
        ssh -i "$KEY" -o ConnectTimeout=15 -o StrictHostKeyChecking=no opc@92.5.18.80 '
            echo "=== UPTIME/MEM ==="; uptime; free -m | head -2
            echo "=== TOP CPU ==="; ps aux --sort=-%cpu | head -12
            echo "=== TOP MEM ==="; ps aux --sort=-%mem | head -8
            echo "=== DISK 6.3G BREAKDOWN ==="; sudo du -x -h --max-depth=1 / 2>/dev/null | sort -rh | head -15
            echo "=== HOME ==="; ls -la ~; du -sh ~/* 2>/dev/null | sort -rh | head -10
            echo "=== DOCKER ==="; command -v docker >/dev/null && { docker ps -a; docker images; } 2>/dev/null || echo no-docker
            echo "=== SYSTEMD RUNNING (custom) ==="; systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | grep -vE "^(systemd|dbus|polkit|sshd|chronyd|rsyslog|firewall|oracle-cloud|NetworkManager|dnf|audit)" | head -15
            echo "=== CRONTAB ==="; crontab -l 2>/dev/null; sudo ls /etc/cron.d/ 2>/dev/null
            echo "=== SHELL HISTORY (last 30) ==="; tail -30 ~/.bash_history 2>/dev/null
            echo "=== LISTENING PORTS ==="; (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | head -15
        ' > "$INV" 2>/dev/null
        echo "$TS inventory saved: $INV" >> "$STATE"
    fi
    # healthy? then rescue-fixes first (kill the thrash), then A1 attempt
    if awk "BEGIN{exit !($LOAD < 2)}" 2>/dev/null; then
        ssh -i "$KEY" -o ConnectTimeout=15 -o StrictHostKeyChecking=no opc@92.5.18.80 'bash -s' <<'FIXES' >> "$LOG" 2>&1
# idempotent rescue kit for the 1GB micro VM
if ! swapon --show | grep -q /swapfile; then
  sudo systemctl disable --now dnf-makecache.timer dnf-makecache.service 2>/dev/null
  sudo dnf clean all -q 2>/dev/null
  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap -q /swapfile && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  echo "RESCUE: swapfile added + dnf-makecache timer disabled"
fi
FIXES
        # A1 exists already? (via working GET from phone)
        TEN=$(grep '^tenancy' "$HOME/.oci/config" | cut -d= -f2 | tr -d ' ')
        A1=$(cd "$HOME/agent_tools" && python -c "
from oci_raw import oci_request
st,d=oci_request('GET','https://iaas.eu-frankfurt-1.oraclecloud.com/20160918/instances?compartmentId=$TEN')
print('YES' if st==200 and any('A1' in i.get('shape','') for i in d) else 'NO')" 2>/dev/null)
        if [ "$A1" = "NO" ]; then
            echo "$TS attempting A1 launch from VM" >> "$LOG"
            ssh -i "$KEY" -o StrictHostKeyChecking=no opc@92.5.18.80 'bash -s' <<'REMOTE' >> "$LOG" 2>&1
export PATH=$HOME/.local/bin:$PATH
command -v oci >/dev/null || { command -v pip3 >/dev/null || sudo dnf install -y -q python3-pip; python3 -m pip install --user -q oci-cli >/dev/null 2>&1; }
command -v oci >/dev/null || exit 0
TEN=$(grep '^tenancy' ~/.oci/config | cut -d= -f2 | tr -d ' ')
for AD in $(oci iam availability-domain list --query 'data[].id' --raw-output 2>/dev/null | tr -d '[],"'); do
  echo "trying $AD"
  OUT=$(oci compute instance launch --availability-domain "$AD" --compartment-id "$TEN" \
    --shape VM.Standard.A1.Flex --shape-config '{"ocpus":2,"memoryInGBs":12}' \
    --image-id ocid1.image.oc1.eu-frankfurt-1.aaaaaaaa4yruuzv353vx4cf3tcsimt5xqvls6reilpxccqhxbyfk6rzn57qq \
    --subnet-id ocid1.subnet.oc1.eu-frankfurt-1.aaaaaaaazd2dqatcagixi4nmv2pvm6aoqvorwvuwooytwfqetkci6wnkmu5q \
    --assign-public-ip true --display-name ampere-a1-1 \
    --ssh-authorized-keys-file ~/.ssh/authorized_keys 2>&1)
  echo "$OUT" | grep -q '"lifecycle-state"' && { echo "SUCCESS"; break; }
  echo "$OUT" | grep -oE 'Out of host capacity|CannotParseRequest|LimitExceeded|NotAuthenticated' | head -1
done
REMOTE
        fi
        # if VM still has no oci-cli after this, log it
        grep -q "SUCCESS" "$LOG" 2>/dev/null && {
            TOKEN=$(cat "$HOME/.credentials/telegram/bot_token" 2>/dev/null)
            CHAT=$(grep -oE '[0-9]{6,}' "$HOME/.credentials/telegram/config" 2>/dev/null | head -1)
            [ -n "$TOKEN" ] && [ -n "$CHAT" ] && curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                -d chat_id="$CHAT" -d text="🚀 A1 Ampere launched! (auto-retry from micro VM succeeded)" >/dev/null
        }
    fi
else
    echo "$TS UNREACHABLE" >> "$STATE"
fi
# keep state file trim
tail -n 500 "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
