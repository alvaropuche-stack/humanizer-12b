#!/usr/bin/env bash
# Register the humanizer Runpod serverless endpoint.
#
#   export RUNPOD_API_KEY=rpa_...
#   ./deploy.sh
#
# THIS SCRIPT BUILDS NOTHING AND DOWNLOADS NOTHING. It only makes Runpod REST
# calls (a few KB each). The image is built by Runpod from this GitHub repo, and
# the 10 GB weight lives on a Runpod network volume seeded from the Singapore
# VPS. Never run `docker build` for this project on a metered connection.
#
# What it does, in order:
#   1. verifies the API key (so a dead key fails before touching anything),
#   2. reuses or creates the network volume,
#   3. reuses or creates the Serverless template pointing at this image,
#   4. reuses or creates the endpoint with workersMin 0.
# Re-running is safe: everything is looked up by name first.
#
# See README.md for the GitHub-connection prerequisite: Runpod's REST API takes
# an image name, not a git repo, so the repo build is configured once in the
# console (Settings -> Connections -> GitHub, then New Endpoint -> Import Git
# Repository). This script then registers the endpoint against that image.
set -euo pipefail

# --- knobs -----------------------------------------------------------------
NAME="${NAME:-humanizer-12b}"
# Runpod's own registry path for an image built from the connected repo. Override
# after the first console build if Runpod reports a different tag.
IMAGE="${IMAGE:-runpod/humanizer-12b:latest}"
GPU_TYPES="${GPU_TYPES:-NVIDIA L4,NVIDIA RTX A5000,NVIDIA GeForce RTX 4090,NVIDIA A40}"
WORKERS_MAX="${WORKERS_MAX:-2}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-120}"
EXECUTION_TIMEOUT_MS="${EXECUTION_TIMEOUT_MS:-900000}"
CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-20}"
# The weight is 10 GB; 20 GB leaves room for a re-upload without resize.
VOLUME_SIZE_GB="${VOLUME_SIZE_GB:-20}"
VOLUME_NAME="${VOLUME_NAME:-humanizer-weights}"
# Must be a datacenter that supports both the S3 API and GPU workers, so the
# volume can be seeded over S3 and mounted by the endpoint.
DATA_CENTER="${DATA_CENTER:-EU-CZ-1}"

# Overridable only so the create/reuse logic can be tested against a stub.
API="${RUNPOD_API:-https://rest.runpod.io/v1}"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

# --- preconditions ---------------------------------------------------------
: "${RUNPOD_API_KEY:?RUNPOD_API_KEY is not set; create one at https://console.runpod.io/user/credentials}"
command -v curl >/dev/null || die "curl is required"
command -v python3 >/dev/null || die "python3 is required"

# --- REST helpers ----------------------------------------------------------
# The key is used in an Authorization header built at call time: never an
# argument, never echoed, never written to disk.
TMP_BODY="$(mktemp)"
TMP_CODE="$(mktemp)"
trap 'rm -f "$TMP_BODY" "$TMP_CODE"' EXIT

# api METHOD PATH [JSON_BODY] -> body on stdout. The HTTP code is left in
# $TMP_CODE as a file so it survives the command substitution's subshell.
api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "${API}${path}"
              -H "Authorization: Bearer ${RUNPOD_API_KEY}"
              -o "$TMP_BODY" -w '%{http_code}')
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  curl "${args[@]}" >"$TMP_CODE" || printf '000' >"$TMP_CODE"
  cat "$TMP_BODY"
}

# require_ok WHAT -> die with a readable message unless the last call was 2xx.
require_ok() {
  local what="$1" status body
  status="$(cat "$TMP_CODE")"
  body="$(cat "$TMP_BODY")"
  case "$status" in
    2??) return 0 ;;
    401|403)
      die "Runpod rejected the API key (HTTP ${status}) while ${what}. Regenerate it at https://console.runpod.io/user/credentials and re-export RUNPOD_API_KEY." ;;
    000) die "cannot reach ${API} while ${what} -- check connectivity" ;;
    *) die "${what} failed (HTTP ${status}): ${body:0:500}" ;;
  esac
}

# find_id NAME_ENV LIST_PATH -- print the id of the object whose name matches.
find_id() {
  local name="$1" path="$2"
  api GET "$path" | OBJ_NAME="$name" python3 -c '
import json, os, sys
name = os.environ["OBJ_NAME"]
try:
    items = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(items, dict):
    items = items.get("data") or items.get("items") or []
for item in items:
    if isinstance(item, dict) and item.get("name") == name:
        print(item.get("id", ""))
        break
'
}

# --- 1. key check ----------------------------------------------------------
say "checking the API key"
api GET /endpoints >/dev/null
require_ok "listing endpoints"

# --- 2. network volume (holds the 10 GB weight) ----------------------------
volume_id="$(find_id "$VOLUME_NAME" /networkvolumes)"
if [ -n "$volume_id" ]; then
  say "reusing network volume ${volume_id} (${VOLUME_NAME})"
else
  say "creating network volume ${VOLUME_NAME} (${VOLUME_SIZE_GB} GB, ${DATA_CENTER})"
  body="$(VOL_NAME="$VOLUME_NAME" VOL_SIZE="$VOLUME_SIZE_GB" DC="$DATA_CENTER" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["VOL_NAME"],
    "size": int(os.environ["VOL_SIZE"]),
    "dataCenterId": os.environ["DC"],
}))')"
  created="$(api POST /networkvolumes "$body")"
  require_ok "creating the network volume"
  volume_id="$(printf '%s' "$created" | python3 -c 'import json,sys
print(json.load(sys.stdin).get("id") or "")')"
  [ -n "$volume_id" ] || die "volume response had no id: ${created}"
  say "network volume ${volume_id}"
fi

# --- 3. template -----------------------------------------------------------
template_id="$(find_id "${NAME}-tpl" /templates)"
if [ -n "$template_id" ]; then
  say "reusing template ${template_id} (${NAME}-tpl)"
else
  say "creating template ${NAME}-tpl"
  body="$(IMAGE_NAME="$IMAGE" TPL="${NAME}-tpl" DISK="$CONTAINER_DISK_GB" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["TPL"],
    "imageName": os.environ["IMAGE_NAME"],
    "isServerless": True,
    "containerDiskInGb": int(os.environ["DISK"]),
    "dockerStartCmd": ["python3", "-u", "handler.py"],
    # The endpoint attaches the volume; the handler verifies the sha256 of the
    # weight it finds there before serving. No download is allowed at runtime.
    "env": {
        "HUMANIZER_LLAMA_BIN": "/opt/llama.cpp/llama-server",
        "HUMANIZER_ALLOW_DOWNLOAD": "0",
    },
}))')"
  created="$(api POST /templates "$body")"
  require_ok "creating the template"
  template_id="$(printf '%s' "$created" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("id") or d.get("templateId") or "")')"
  [ -n "$template_id" ] || die "template response had no id: ${created}"
  say "template ${template_id}"
fi

# --- 4. endpoint -----------------------------------------------------------
endpoint_id="$(find_id "$NAME" /endpoints)"
if [ -n "$endpoint_id" ]; then
  say "endpoint ${NAME} already exists (${endpoint_id}); not creating a duplicate"
else
  say "creating endpoint ${NAME} (workersMin=0)"
  body="$(TPL_ID="$template_id" EP_NAME="$NAME" GPUS="$GPU_TYPES" \
          WMAX="$WORKERS_MAX" IDLE="$IDLE_TIMEOUT" EXECMS="$EXECUTION_TIMEOUT_MS" \
          VOL="$volume_id" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["EP_NAME"],
    "templateId": os.environ["TPL_ID"],
    "computeType": "GPU",
    "gpuTypeIds": [g.strip() for g in os.environ["GPUS"].split(",") if g.strip()],
    "gpuCount": 1,
    # 0 means no worker runs, and nothing is billed, while idle.
    "workersMin": 0,
    "workersMax": int(os.environ["WMAX"]),
    "idleTimeout": int(os.environ["IDLE"]),
    # Generous: a cold start must finish loading 10 GB before the first token.
    "executionTimeoutMs": int(os.environ["EXECMS"]),
    "scalerType": "QUEUE_DELAY",
    "scalerValue": 4,
    "minCudaVersion": "12.8",
    "allowedCudaVersions": ["12.8", "12.9", "13.0"],
    "networkVolumeIds": [os.environ["VOL"]],
}))')"
  created="$(api POST /endpoints "$body")"
  require_ok "creating the endpoint"
  endpoint_id="$(printf '%s' "$created" | python3 -c 'import json,sys
print(json.load(sys.stdin).get("id") or "")')"
  [ -n "$endpoint_id" ] || die "endpoint response had no id: ${created}"
  say "endpoint ${endpoint_id}"
fi

cat <<EOF

endpoint id   : ${endpoint_id}
volume id     : ${volume_id}
image         : ${IMAGE}
invoke (sync) : https://api.runpod.ai/v2/${endpoint_id}/runsync
invoke (async): https://api.runpod.ai/v2/${endpoint_id}/run
health        : https://api.runpod.ai/v2/${endpoint_id}/health

Before the first successful request the volume must hold the verified weight:

  ./seed-volume.sh          # one-off, copies 10 GB from vps-sg over S3

workersMin is 0: idle costs nothing. The first request after idle pays a cold
start (llama-server boot + 10 GB weight load from the volume), roughly
60-150 s. Later requests stay warm until idleTimeout (${IDLE_TIMEOUT}s).

Point the CLI at it and verify in one line:

  export HUMANIZER_URL=https://api.runpod.ai/v2/${endpoint_id}
  export HUMANIZER_API_KEY="\$RUNPOD_API_KEY"
  humanize --check
  humanize draft.txt
EOF
