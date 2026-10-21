# humanizer-12b on Runpod serverless

Serverless endpoint that rewrites AI-sounding drafts into human-sounding prose
with `jialinyyzz/humanizer`, a Gemma-4 12B Q6_K finetune
(`humanizer-12b-Q6_K.gguf`, 10,029,799,584 bytes).

**Status: packaged and stub-tested, never deployed.** No Runpod resource exists
yet and the image has never been built. See [UNVERIFIED](#unverified).

---

## RULE: no bulk downloads on the deploying laptop

Whoever picks this up next, read this first.

**This must never be built or pulled on the Mac.** A local `docker build` means
the CUDA base plus the 10 GB weight over a metered mobile uplink. That has
already been started twice by mistake and stopped twice. Nothing in this package
requires it.

Where bytes are allowed to move:

| What | Where it happens |
|---|---|
| The worker image build | GitHub Actions runner, or `vps-sg` |
| The 10 GB weight | Once, from `vps-sg` to Runpod's S3, i.e. VPS -> Runpod |
| The CUDA base | Inside GitHub Actions or Runpod, never here |

On the Mac you may read and edit these ~40 KB of text files and make API calls
that return a few KB. That is all.

`vps-sg` (user `ubuntu`) already holds the sha256-verified weight at
`~/models/humanizer/humanizer-12b-Q6_K.gguf`. **Do not delete that copy until
the endpoint has answered a real request in production** — it is the seed of
record for the network volume, and re-downloading 10 GB is exactly what this
rule exists to prevent.

## Layout

```
Dockerfile                     builds with the repo root as context
handler.py                     Runpod handler; boots llama-server once
check_contract.py              build-time prompt-contract assertion
seed-volume.sh                 one-off: copies the weight from vps-sg to the volume
deploy.sh                      Runpod REST calls only; builds nothing
build-on-vps.sh                fallback image build on vps-sg
.dockerignore
.github/workflows/build.yml    image build on GitHub runners
README.md
```

Push this directory as the root of a GitHub repository. The Dockerfile builds
with that root as context and needs nothing outside it.

## Architecture and why

Runpod's REST API cannot take a git repository for a Serverless template. Its
`TemplateCreateInput` schema accepts exactly `name`, `imageName`,
`containerDiskInGb`, `dockerEntrypoint`, `dockerStartCmd`, `env`, `ports`,
`volumeInGb`, `volumeMountPath`, `containerRegistryAuthId`, `category`,
`isPublic`, `isServerless`, `readme` — there is no repository, branch or
Dockerfile-path field anywhere in the specification, and the string `github`
does not appear in `https://rest.runpod.io/v1/openapi.json` at all. The repo
build exists only in the console (**New Endpoint -> Import Git Repository**),
and Runpod's docs state it needs a one-time GitHub connection under
Settings -> Connections.

So the image is built by infrastructure that is not the laptop, in this order of
preference:

1. **GitHub Actions** (`.github/workflows/build.yml`) pushes
   `ghcr.io/<owner>/humanizer-12b:latest`. Preferred: GitHub's runners have
   docker and bandwidth, and the weight layer never touches Runpod's 30-minute
   docker-build limit.
2. **Runpod's own GitHub integration**, if the repo is connected in the console.
   This is the only path that produces an image in `runpod/`'s registry.
3. **`build-on-vps.sh` on `vps-sg`** — last resort. That host has 2 vCPU, 3 GB
   RAM and 24 GB free disk, so the script refuses to start under 10 GB free.

Whichever path runs, `deploy.sh` then registers the endpoint against the
resulting image with `IMAGE=...`.

## Weight delivery: network volume, not the image

Chosen option: **(a) a Runpod network volume holding the 10 GB, with
`SKIP_MODEL=1`.**

- The volume is durable and independent of image rebuilds, so a handler edit
  never re-fetches 10 GB. Baking the model in would make every `COPY handler.py`
  invalidate a 10 GB layer.
- It can be seeded over Runpod's S3-compatible API straight from `vps-sg`, which
  already has the verified file. No hop through the Mac.
- The image stays ~2.5 GB compressed instead of ~12 GB, which matters because
  Runpod's GitHub builder caps a docker build at 30 minutes.

Rejected: **(b) fetch at container start.** It works — `handler.py` implements
it behind `HUMANIZER_ALLOW_DOWNLOAD=1` — but a cold worker would spend minutes
downloading 10 GB from Hugging Face on every fresh worker, and a failed download
would surface as an opaque cold-start timeout. It stays available as a
bootstrap, not as the design.

Rejected: **(c) bake into the image.** Largest image, slowest build, and the
weight cannot be updated without a full rebuild.

The sha256 check is mandatory on every path: `handler.py` verifies size and
sha256 of whatever it loads, and refuses to start llama-server on a mismatch. A
runtime download writes to a `.part` file and only renames it after the hash
matches, so a killed worker cannot leave a half file that looks complete.

### Seeding the volume (once, on the VPS)

```bash
ssh vps-sg
export RUNPOD_S3_ACCESS_KEY=user_...     # Runpod S3 API key, not the Runpod API key
export RUNPOD_S3_SECRET_KEY=rps_...
export NETWORK_VOLUME_ID=<id printed by deploy.sh>
./seed-volume.sh
```

It verifies the local sha256 first, skips the upload when the remote object is
already the right size, and re-checks the uploaded size. `boto3` is already
installed on `vps-sg`.

## Deploying

```bash
cd ~/models/humanizer/runpod
export RUNPOD_API_KEY=rpa_...            # never an argument, never echoed
./deploy.sh                              # pass IMAGE=... if not using the default
```

One command, once a valid key exists. It:

1. verifies the key via `GET /endpoints` — a 401 fails before anything is
   created, and never with the key in the message,
2. reuses or creates the network volume,
3. reuses or creates the template,
4. reuses or creates the endpoint with `workersMin: 0`,
5. prints the endpoint id, volume id and invoke URLs.

Re-running is safe: every object is looked up by name and reused, so it cannot
duplicate.

Knobs (all environment variables): `NAME`, `IMAGE`, `GPU_TYPES`, `WORKERS_MAX`,
`IDLE_TIMEOUT`, `EXECUTION_TIMEOUT_MS`, `CONTAINER_DISK_GB`, `VOLUME_SIZE_GB`,
`VOLUME_NAME`, `DATA_CENTER`.

**The key currently returns HTTP 401.** It must be regenerated at
<https://console.runpod.io/user/credentials> before `deploy.sh` will get past
step 1.

## Invoking the endpoint

Runpod wraps the input in `{"input": ...}`:

```bash
ENDPOINT=<the id deploy.sh printed>
curl -sS "https://api.runpod.ai/v2/${ENDPOINT}/runsync" \
  -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"input": {"draft": "Our team is committed to leveraging synergistic solutions."}}'
```

```json
{
  "id": "…",
  "status": "COMPLETED",
  "output": {
    "rewritten": "We'll stop saying synergistic.",
    "prompt_sha16": "cc51d66b4c593fbe",
    "truncated": false,
    "chars_in": 62,
    "chars_out": 27
  }
}
```

`/runsync` returns when the job finishes, or `IN_QUEUE` for long jobs — then poll
`GET /v2/${ENDPOINT}/status/<job id>`. `truncated: true` means the rewrite hit
the 2048-token cap: split the draft. Errors come back as `output.error` text,
never as an opaque stack trace.

Sampling is fixed and not per-request: temperature 1.0, top_p 0.95, top_k 0,
min_p 0, repeat_penalty 1.0, n_predict 2048, 8192 context, **no stop strings**
(`###` would truncate real rewrites). The prompt is
`instr + "\n\n" + draft.strip() + sep`; `sha256[:16]` of the probe is
`cc51d66b4c593fbe`, asserted at handler import *and* at image build time.

## Cold start and cost

`workersMin: 0`: no worker exists while idle, so idle costs exactly zero. The
first request after idle pays a cold start — host boot (~10-30 s) plus loading
10 GB from the volume and starting llama-server (~30-90 s), so **60-150 s**.
Requests afterwards stay warm until `idleTimeout` (120 s by default).
`executionTimeoutMs` is 15 minutes, which covers cold start plus a full rewrite.

You pay only for worker-seconds while serving. Setting `workersMin: 1` for a
permanently warm worker turns that into a 24 h bill — don't, unless you need it.

## Pointing the local CLI at it

`~/.local/bin/humanize` already speaks both shapes and picks the transport from
`HUMANIZER_URL`:

```bash
export HUMANIZER_URL="https://api.runpod.ai/v2/${ENDPOINT}"
export HUMANIZER_API_KEY="$RUNPOD_API_KEY"
humanize --check        # endpoint, transport, prompt hash, reachability
humanize draft.txt
```

Accepted URL forms:

```
https://api.runpod.ai/v2/<id>          -> .../v2/<id>/runsync   (runpod envelope)
https://api.runpod.ai/v2/<id>/runsync  -> same
http://127.0.0.1:8090                  -> .../completion        (llama.cpp)
http://127.0.0.1:8090/completion       -> unchanged
```

Unset `HUMANIZER_URL` still means the local server on `127.0.0.1:8090`.

## UNVERIFIED

The following has **never been executed**. The package is reasoning plus
stub-level tests, not a proven deployment. Do not treat it as tested.

1. **The image has never been built.** `docker build` was started once on the
   Mac and cancelled on purpose (metered uplink); no image was produced. Layer
   ordering, the `apt-get` line, the llama.cpp tarball extraction and the
   `pip install runpod==1.12.0` step have therefore never run together.
2. **The pinned llama.cpp URL has not been downloaded here.** It resolves
   (HTTP 302 to the release asset), and its sha256 was computed from a copy
   fetched before the no-download rule was in force — but the tarball has not
   been re-verified in this state, and the release could not be inspected for a
   different `--strip-components` layout.
3. **The base image tag `nvidia/cuda:12.8.2-runtime-ubuntu24.04` exists**
   (registry manifest resolves, amd64 + arm64). Its contents are unverified
   beyond the manifest: in particular, whether `python3` and `pip` behave as
   expected under `--break-system-packages`.
4. **`libssl3t64` is unverified as an apt package name.** It is the correct
   Ubuntu 24.04 name for the OpenSSL 3 runtime by the t64 rename convention, but
   no `apt-cache` or build has confirmed it resolves on this base. If it fails,
   the build fails fast on the `apt-get` line and the fix is one word.
5. **`handler.py` has never run against a real llama-server or GPU.** It was
   exercised with the server start stubbed out, proving the prompt, the sampling
   payload, the error strings and the Chinese-resample guard. The boot path,
   `/health` wait, weight verification against the real 10 GB file, and
   `-ngl 99` offload are unproven.
6. **No Runpod resource was ever created.** `deploy.sh` was tested end-to-end
   against a local stub of the REST API (create, reuse, 401 handling, key never
   leaked), but never against `rest.runpod.io`. Field names come from the
   published OpenAPI schema; whether the live API accepts `networkVolumeIds` on
   endpoint creation, and whether `EU-CZ-1` is a valid `dataCenterId` for a
   volume, are unconfirmed.
7. **The default `IMAGE` (`runpod/humanizer-12b:latest`) is a guess.** Runpod's
   registry path for a console-built repo image is not documented. After the
   first console build, replace it with the tag Runpod reports.
8. **`seed-volume.sh` has never uploaded.** `boto3` is present on `vps-sg` and
   the S3 endpoint format comes from Runpod's docs, but the upload, the
   `head_object` skip path, and multipart behaviour on a 10 GB object are
   untested.
9. **The GitHub Actions workflow has never run.** YAML parses; the GHCR push
   path and the `packages: write` permission on a fresh repo are unproven.
10. **The CLI's Runpod transport has never talked to a real endpoint**, only to
    a local stub that mimics `/runsync` and `/status/<id>`.
