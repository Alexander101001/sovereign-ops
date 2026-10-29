#!/usr/bin/env python3
"""Portable OCI raw signer for CI — signs and executes one request using env creds.
Env: OCI_TENANCY, OCI_USER, OCI_FINGERPRINT, OCI_KEY_B64, OCI_REGION
Usage:
  oci_signed.py get-instances                     -> prints JSON list of instances
  oci_signed.py launch <AD_OCID>                  -> attempts A1 launch, prints classification
No oci SDK needed; only requests + cryptography (both preinstalled on GH runners).
"""
import base64, hashlib, json, os, sys
from datetime import datetime, timezone
from urllib.parse import urlparse
import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

REGION = os.environ["OCI_REGION"]
BASE = f"https://iaas.{REGION}.oraclecloud.com/20160918"
TEN = os.environ["OCI_TENANCY"]
KEY = serialization.load_pem_private_key(
    base64.b64decode(os.environ["OCI_KEY_B64"]), password=None)


def sign(method, path_with_query, headers):
    names = ["(request-target)", "host", "date"] + [
        h for h in ["x-content-sha256", "content-type", "content-length"] if h in headers]
    parts = []
    for n in names:
        if n == "(request-target)":
            parts.append(f"(request-target): {method.lower()} {path_with_query}")
        elif n == "host":
            parts.append(f"host: {headers['host']}")
        else:
            parts.append(f"{n}: {headers[n]}")
    ss = "\n".join(parts).encode()
    sig = base64.b64encode(KEY.sign(ss, padding.PKCS1v15(), hashes.SHA256())).decode()
    keyid = f'{os.environ["OCI_TENANCY"]}/{os.environ["OCI_USER"]}/{os.environ["OCI_FINGERPRINT"]}'
    headers["authorization"] = (
        f'Signature version="1",keyId="{keyid}",algorithm="rsa-sha256",'
        f'headers="{" ".join(names)}",signature="{sig}"')


def req(method, path, body=None):
    p = urlparse(BASE + path)
    headers = {"host": p.netloc,
               "date": datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")}
    data = None
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode()
        headers["x-content-sha256"] = base64.b64encode(hashlib.sha256(data).digest()).decode()
        headers["content-type"] = "application/json"
        headers["content-length"] = str(len(data))
    sign(method, p.path + (("?" + p.query) if p.query else ""), headers)
    r = requests.request(method, BASE + path, data=data, headers=headers, timeout=60)
    try:
        return r.status_code, r.json()
    except Exception:
        return r.status_code, r.text


def main():
    cmd = sys.argv[1]
    if cmd == "curl-cmd":
        # Build a FRESH signed request and print a curl command for remote execution
        # (used to hand the launch to the micro VM: sign here, execute there).
        ad, outdir = sys.argv[2], sys.argv[3]
        import os as _os
        _os.makedirs(outdir, exist_ok=True)
        pub = open("keys/a1.pub").read().strip()
        ci = base64.b64encode(open("cloud-init/a1.yaml", "rb").read()).decode()
        body = {
            "availabilityDomain": ad, "compartmentId": TEN,
            "shape": "VM.Standard.A1.Flex",
            "shapeConfig": {"ocpus": 2, "memoryInGBs": 12},
            "sourceDetails": {"sourceType": "image",
                "imageId": "ocid1.image.oc1.eu-frankfurt-1.aaaaaaaa4yruuzv353vx4cf3tcsimt5xqvls6reilpxccqhxbyfk6rzn57qq"},
            "createVnicDetails": {"subnetId": "ocid1.subnet.oc1.eu-frankfurt-1.aaaaaaaazd2dqatcagixi4nmv2pvm6aoqvorwvuwooytwfqetkci6wnkmu5q",
                                  "assignPublicIp": True},
            "displayName": "ampere-a1-1",
            "metadata": {"ssh_authorized_keys": pub, "user_data": ci},
        }
        data = json.dumps(body, separators=(",", ":")).encode()
        with open(f"{outdir}/oci_body.json", "wb") as f:
            f.write(data)
        p = urlparse(BASE + "/instances")
        headers = {"host": p.netloc,
                   "date": datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT"),
                   "x-content-sha256": base64.b64encode(hashlib.sha256(data).digest()).decode(),
                   "content-type": "application/json",
                   "content-length": str(len(data))}
        sign("POST", "/instances", headers)
        hdrs = " ".join(f"-H '{k}: {v}'" for k, v in headers.items() if k != "host")
        print(f"curl -s -X POST 'https://{p.netloc}{p.path}' -H 'Authorization: {headers['authorization']}' {hdrs} --data-binary @/tmp/oci_body.json")
    elif cmd == "get-instances":
        st, d = req("GET", f"/instances?compartmentId={TEN}")
        if st != 200:
            print(f"LIST_FAILED {st}"); sys.exit(0)
        print(json.dumps(d)) if isinstance(d, list) else print(json.dumps(d.get("data", [])))
    elif cmd == "launch":
        ad = sys.argv[2]
        pub = open("keys/a1.pub").read().strip()
        ci = base64.b64encode(open("cloud-init/a1.yaml", "rb").read()).decode()
        body = {
            "availabilityDomain": ad, "compartmentId": TEN,
            "shape": "VM.Standard.A1.Flex",
            "shapeConfig": {"ocpus": 2, "memoryInGBs": 12},
            "sourceDetails": {"sourceType": "image",
                "imageId": "ocid1.image.oc1.eu-frankfurt-1.aaaaaaaa4yruuzv353vx4cf3tcsimt5xqvls6reilpxccqhxbyfk6rzn57qq"},
            "createVnicDetails": {"subnetId": "ocid1.subnet.oc1.eu-frankfurt-1.aaaaaaaazd2dqatcagixi4nmv2pvm6aoqvorwvuwooytwfqetkci6wnkmu5q",
                                  "assignPublicIp": True},
            "displayName": "ampere-a1-1",
            "metadata": {"ssh_authorized_keys": pub, "user_data": ci},
        }
        st, d = req("POST", "/instances", body)
        txt = json.dumps(d)
        if st in (200, 201):
            print("LAUNCHED")
            print(txt[:800])
        else:
            for c in ["Out of host capacity", "CannotParseRequest", "LimitExceeded",
                      "QuotaExceeded", "NotAuthenticated", "NotAuthorizedOrNotFound"]:
                if c in txt:
                    print(c); break
            else:
                print(f"OTHER_{st}: {txt[:200]}")


if __name__ == "__main__":
    main()
