#!/bin/bash
# A1 Ampere auto-launch (2 OCPU/12GB — post-June-2026 free limit). Idempotent.
# Exit 0 in ALL expected outcomes (no capacity, Oracle API issue, already exists)
# so the 30-min schedule loop never red-fails; only a successful launch exits via Telegram alert.
set -u
mkdir -p ~/.oci
echo "$OCI_KEY_B64" | base64 -d > ~/.oci/oci_api_key.pem
chmod 600 ~/.oci/oci_api_key.pem
printf '[DEFAULT]\nuser=%s\nfingerprint=%s\ntenancy=%s\nregion=%s\nkey_file=%s\n' \
  "$OCI_USER" "$OCI_FINGERPRINT" "$OCI_TENANCY" "$OCI_REGION" "$HOME/.oci/oci_api_key.pem" > ~/.oci/config
chmod 600 ~/.oci/config
export PATH="$HOME/.local/bin:$PATH"
command -v oci >/dev/null || pip install -q oci-cli

EXISTING=$(oci compute instance list --compartment-id "$OCI_TENANCY" --all \
  --query 'data[?contains(shape, `A1.Flex`) && lifecycle-state != `TERMINATED`].id' \
  --raw-output 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$EXISTING" ]; then
  echo "OCI list FAILED — creds or API issue; will retry next cycle"
  exit 0
fi
if [ "$EXISTING" != "[]" ]; then
  echo "A1 already exists: $EXISTING"
  exit 0
fi

IMG="ocid1.image.oc1.eu-frankfurt-1.aaaaaaaa4yruuzv353vx4cf3tcsimt5xqvls6reilpxccqhxbyfk6rzn57qq"
SUBNET="ocid1.subnet.oc1.eu-frankfurt-1.aaaaaaaazd2dqatcagixi4nmv2pvm6aoqvorwvuwooytwfqetkci6wnkmu5q"
# Frankfurt ADs (rotated per run so all 3 get tried over time)
AD1="ocid1.availabilitydomain.oc1..aaaaaaaaa2artt5wizbqvwl3rgptylx2l7jqbnyv4dygcfvlrd3dphvi3mdq"
AD2="ocid1.availabilitydomain.oc1..aaaaaaaaiifj24st3w4j7cowuo3pmqcuqwjapjv435vtjmgh5j7q3flguwna"
AD3="ocid1.availabilitydomain.oc1..aaaaaaaaalcdcbl7u6akbmkojxhrozpj2v7yavqqydkj3ytyjbt47lnoqnm2q"
ROT=$(($(date +%s) / 1800 % 3))
case $ROT in 0) ADS="$AD1 $AD2 $AD3";; 1) ADS="$AD2 $AD3 $AD1";; 2) ADS="$AD3 $AD1 $AD2";; esac

PARSE_ERRORS=0
for AD in $ADS; do
  ADN=$(echo "$AD" | grep -oE 'aaaa[a-z0-9]{8}' | head -1 | cut -c1-6)
  OUT=$(oci compute instance launch --availability-domain "$AD" --compartment-id "$OCI_TENANCY" \
    --shape VM.Standard.A1.Flex --shape-config '{"ocpus":2,"memoryInGBs":12}' \
    --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
    --display-name ampere-a1-1 \
    --user-data-file cloud-init/a1.yaml \
    --ssh-authorized-keys-file keys/a1.pub 2>&1) || true
  if echo "$OUT" | grep -q '"lifecycle-state"'; then
    echo "LAUNCHED in $AD"
    IP=$(echo "$OUT" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
      -d chat_id="$TG_CHAT" \
      -d text="🚀 A1 Ampere LAUNCHED (2 OCPU/12GB) via GitHub Actions! AD=${ADN} IP=${IP:-pending}" >/dev/null
    exit 0
  fi
  CODE=$(echo "$OUT" | grep -oE 'Out of host capacity|CannotParseRequest|LimitExceeded|QuotaExceeded|NotAuthenticated|NotAuthorizedOrNotFound' | head -1)
  echo "AD ${ADN:-?}: ${CODE:-UNKNOWN: $(echo "$OUT" | head -c 150)}"
  [ "$CODE" = "CannotParseRequest" ] && PARSE_ERRORS=$((PARSE_ERRORS+1))
done

if [ "$PARSE_ERRORS" -gt 0 ]; then
  echo "NOTE: Frankfurt API returning CannotParseRequest for POSTs (Oracle-side, GETs fine). Keep retrying — lands automatically when Oracle fixes it."
fi
echo "No capacity this round"
