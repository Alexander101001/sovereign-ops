#!/bin/bash
# VM health + rescue + A1-via-VM launcher for GitHub Actions (every 20 min).
# Three chances to launch the A1 each cycle: direct POST (if Oracle API works),
# then via the micro VM (Oracle-internal network path) across AD-1.
set -u
mkdir -p ~/.ssh state
echo "$VM_SSH_KEY" > ~/.ssh/oci_vm_key; chmod 600 ~/.ssh/oci_vm_key
ssh-keyscan -H 92.5.18.80 >> ~/.ssh/known_hosts 2>/dev/null

SSH="ssh -i ~/.ssh/oci_vm_key -o ConnectTimeout=20 -o StrictHostKeyChecking=no opc@92.5.18.80"
OUT=$(timeout 45 $SSH 'uptime; free -m | head -2' 2>&1) || OUT="UNREACHABLE: $OUT"
echo "$OUT"

if echo "$OUT" | grep -q "load average"; then
  LOAD=$(echo "$OUT" | grep -oE 'load average: [0-9.]+' | grep -oE '[0-9.]+$')
  if awk "BEGIN{exit !($LOAD < 2)}"; then
    RESCUE=$(timeout 60 $SSH 'bash -s' < scripts/vm_rescue.sh 2>&1) || RESCUE="rescue-failed"
    echo "RESCUE: $RESCUE"
  fi

  # A1 exists? (GET works even while Frankfurt POSTs misparse)
  LIST=$(python3 scripts/oci_signed.py get-instances 2>&1)
  if echo "$LIST" | grep -q "LIST_FAILED"; then echo "instance list failed: $LIST"; exit 0; fi
  if echo "$LIST" | grep -q "A1.Flex"; then echo "A1 already exists"; exit 0; fi

  echo "A1 missing — attempt 1: direct signed POST from runner..."
  python3 scripts/oci_signed.py launch \
    "ocid1.availabilitydomain.oc1..aaaaaaaaa2artt5wizbqvwl3rgptylx2l7jqbnyv4dygcfvlrd3dphvi3mdq" > /tmp/launch1.txt 2>&1
  echo "attempt1: $(head -1 /tmp/launch1.txt)"
  if grep -q "^LAUNCHED$" /tmp/launch1.txt; then
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
      -d chat_id="$TG_CHAT" -d text="🚀 A1 Ampere LAUNCHED (2 OCPU/12GB) — direct signed POST worked!" >/dev/null
    exit 0
  fi

  # Attempt 2: sign fresh on runner, execute curl on the micro VM (Oracle-internal path)
  echo "attempt 2: VM path..."
  python3 scripts/oci_signed.py curl-cmd \
    "ocid1.availabilitydomain.oc1..aaaaaaaaa2artt5wizbqvwl3rgptylx2l7jqbnyv4dygcfvlrd3dphvi3mdq" /tmp > /tmp/launch2.txt 2>&1
  if [ -s /tmp/oci_body.json ]; then
    timeout 40 scp -i ~/.ssh/oci_vm_key -o StrictHostKeyChecking=no /tmp/oci_body.json opc@92.5.18.80:/tmp/ >/dev/null 2>&1
    RESP=$(timeout 45 $SSH 'bash /tmp/launch2.txt 2>&1 | head -c 800' 2>/dev/null) || RESP="ssh-failed"
    echo "vm-path: $(echo "$RESP" | head -c 200)"
    if echo "$RESP" | grep -q '"lifecycle-state"'; then
      IP=$(echo "$RESP" | grep -oE '"publicIp" *: *"[0-9.]+"' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
      curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT" -d text="🚀 A1 Ampere LAUNCHED via VM path (2 OCPU/12GB)! IP=${IP:-pending}" >/dev/null
      exit 0
    fi
  else
    echo "sign-for-vm failed: $(cat /tmp/launch2.txt)"
  fi
  echo "No A1 this cycle"
else
  NOW=$(date +%s)
  [ -f state/vm_down_since ] || echo "$NOW" > state/vm_down_since
  ELAPSED=$(( NOW - $(cat state/vm_down_since) ))
  echo "VM unreachable for ${ELAPSED}s"
  if [ "$ELAPSED" -gt 10800 ]; then
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
      -d chat_id="$TG_CHAT" -d text="⚠️ Micro VM down >3h ($(date -u +%H:%M UTC)) — needs attention" || true
    echo "$NOW" > state/vm_down_since
    git config user.name "sovereign-bot"; git config user.email "bot@sovereign.ops"
    git add state/ 2>/dev/null || true
    if ! git diff --cached --quiet; then git commit -m "state: vm down $(date -u +%FT%TZ)"; git push; fi
  fi
fi
