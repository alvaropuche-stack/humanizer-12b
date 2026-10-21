#!/usr/bin/env bash
# Seed the Runpod network volume with the verified 10 GB weight.
#
# RUN THIS ON vps-sg, NOT ON THE MAC. It reads the already-verified GGUF from
# ~/models/humanizer/ on the VPS and uploads it to the network volume over
# Runpod's S3-compatible API. The VPS has the file and the bandwidth; the Mac
# never sees a byte of it.
#
#   ssh vps-sg
#   export RUNPOD_S3_ACCESS_KEY=user_...      # S3 API key, NOT the Runpod key
#   export RUNPOD_S3_SECRET_KEY=rps_...
#   export NETWORK_VOLUME_ID=<id from deploy.sh>
#   ./seed-volume.sh
#
# Idempotent: the object is uploaded only when its remote size differs, and the
# local file's sha256 is re-verified before any upload starts.
set -euo pipefail

MODEL="${MODEL:-$HOME/models/humanizer/humanizer-12b-Q6_K.gguf}"
MODEL_SHA256="c98f03bb9e71456181f99b0e1d3391e07ce1afc357f9db4c33d6d379b8dd9f0d"
MODEL_BYTES=10029799584
KEY="humanizer-12b-Q6_K.gguf"
DATACENTER="${DATACENTER:-EU-CZ-1}"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'seed-volume: %s\n' "$*" >&2; exit 1; }

: "${RUNPOD_S3_ACCESS_KEY:?set RUNPOD_S3_ACCESS_KEY (Runpod S3 API key access key)}"
: "${RUNPOD_S3_SECRET_KEY:?set RUNPOD_S3_SECRET_KEY (Runpod S3 API key secret)}"
: "${NETWORK_VOLUME_ID:?set NETWORK_VOLUME_ID (the id deploy.sh printed)}"

ENDPOINT="https://s3api-$(printf '%s' "$DATACENTER" | tr '[:upper:]' '[:lower:]').runpod.io/"

[ -f "$MODEL" ] || die "no model at $MODEL"
size="$(stat -c %s "$MODEL")"
[ "$size" = "$MODEL_BYTES" ] || die "$MODEL is $size bytes, expected $MODEL_BYTES"

say "verifying sha256 of $MODEL (a few minutes on 10 GB)"
got="$(sha256sum "$MODEL" | cut -d' ' -f1)"
[ "$got" = "$MODEL_SHA256" ] || die "sha256 mismatch: $got"
say "sha256 ok"

export RUNPOD_S3_ACCESS_KEY RUNPOD_S3_SECRET_KEY NETWORK_VOLUME_ID ENDPOINT KEY MODEL DATACENTER
python3 - <<'PY'
import os, sys
import boto3
from botocore.config import Config
from boto3.s3.transfer import TransferConfig

bucket = os.environ["NETWORK_VOLUME_ID"]
key = os.environ["KEY"]
path = os.environ["MODEL"]
size = os.path.getsize(path)

s3 = boto3.client(
    "s3",
    aws_access_key_id=os.environ["RUNPOD_S3_ACCESS_KEY"],
    aws_secret_access_key=os.environ["RUNPOD_S3_SECRET_KEY"],
    region_name=os.environ["DATACENTER"],
    endpoint_url=os.environ["ENDPOINT"],
    config=Config(retries={"max_attempts": 10, "mode": "standard"},
                  signature_version="s3v4"),
)

try:
    head = s3.head_object(Bucket=bucket, Key=key)
    remote = head["ContentLength"]
except Exception as exc:
    remote = None
    print("no existing object (%s)" % type(exc).__name__)

if remote == size:
    print("already seeded: %s is %d bytes -- nothing to do" % (key, size))
    sys.exit(0)

print("uploading %s (%.2f GB) -> s3://%s/%s" % (path, size / 1e9, bucket, key))
cfg = TransferConfig(multipart_threshold=64 * 1024 * 1024,
                     multipart_chunksize=64 * 1024 * 1024,
                     max_concurrency=4)
s3.upload_file(path, bucket, key, Config=cfg)

head = s3.head_object(Bucket=bucket, Key=key)
assert head["ContentLength"] == size, (head["ContentLength"], size)
print("seeded %s (%d bytes)" % (key, size))
PY

say "done: s3://${NETWORK_VOLUME_ID}/${KEY} at ${ENDPOINT}"
say "the handler verifies the sha256 again at worker start before serving"
