#!/bin/bash
# A1 Ampere auto-launch (2 OCPU/12GB — post-June-2026 free limit). Idempotent.
set -u
mkdir -p ~/.oci
echo "$OCI_KEY_B64" | base64 -d > ~/.oci/oci_api_key.pem
chmod 600 ~/.oci/oci_api_key.pem
printf '[DEFAULT]\nuser=%s\nfingerprint=%s\ntenancy=%s\nregion=%s\nkey_file=%s\n' \
  "$OCI_USER" "$OCI_FINGERPRINT" "$OCI_TENANCY" "$OCI_REGION" "$HOME/.oci/oci_api_key.pem" > ~/.oci/config
chmod 600 ~/.oci/config
export PATH="$HOME/.local/bin:$PATH"
command -v oci >/dev/null || pip install -q oci-cli
RAW=$(oci compute instance list --compartment-id "$OCI_TENANCY" 2>&1) || { echo "LIST FAILED: $RAW" | head -5; exit 1; }; EXISTING=$(echo "$RAW" | oci ... )
if [ "$EXISTING" != "[]" ] && [ "$EXISTING" != "ERR" ] && [ -n "$EXISTING" ]; then
  echo "A1 already exists: $EXISTING"; exit 0
fi
if [ "$EXISTING" = "ERR" ]; then echo "OCI API read failed — check creds/config"; exit 1; fi
IMG="ocid1.image.oc1.eu-frankfurt-1.aaaaaaaa4yruuzv353vx4cf3tcsimt5xqvls6reilpxccqhxbyfk6rzn57qq"
SUBNET="ocid1.subnet.oc1.eu-frankfurt-1.aaaaaaaazd2dqatcagixi4nmv2pvm6aoqvorwvuwooytwfqetkci6wnkmu5q"
ADS=$(oci iam availability-domain list --query 'data[].id' --raw-output | tr -d '[],"' || true)
[ -z "$ADS" ] && { echo "cannot list ADs"; exit 1; }
for AD in $ADS; do
  ADN=$(echo "$AD" | grep -o 'AD-[0-9]')
  OUT=$(oci compute instance launch --availability-domain "$AD" --compartment-id "$OCI_TENANCY" \
    --shape VM.Standard.A1.Flex --shape-config '{"ocpus":2,"memoryInGBs":12}' \
    --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
    --display-name ampere-a1-1 \
    --user-data-file cloud-init/a1.yaml \
    --ssh-authorized-keys-file keys/a1.pub 2>&1) || true
  echo "$OUT" | grep -q '"lifecycle-state"' && {
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
      -d chat_id="$TG_CHAT" -d text="🚀 A1 Ampere LAUNCHED in $ADN (2 OCPU/12GB) via GitHub Actions!" >/dev/null
    exit 0; }
  echo "AD $ADN: $(echo "$OUT" | grep -oE 'Out of host capacity|CannotParseRequest|LimitExceeded|NotAuthenticat[A-Za-z]*|NotAuthoriz[A-Za-z]*' | head -1)"
done
echo "No capacity this round"
