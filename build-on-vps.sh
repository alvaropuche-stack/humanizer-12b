#!/usr/bin/env bash
# Fallback only: build the worker image on vps-sg and push it to GHCR.
#
#   ssh vps-sg
#   export GITHUB_TOKEN=ghp_...          # with write:packages
#   export IMAGE=ghcr.io/<owner>/humanizer-12b:latest
#   ./build-on-vps.sh
#
# Use this only when the GitHub Actions build is not an option. Prefer the
# workflow in .github/workflows/build.yml: GitHub's runners already have
# docker, and this VPS has 2 vCPU / 3 GB RAM / 24 GB free disk, so building a
# ~2.5 GB image here is slow and leaves little headroom.
#
# Requires ~6 GB free disk: base layers plus the built image plus push
# overhead. The script refuses to start below 10 GB free so a half-finished
# build cannot fill the root filesystem that also hosts live sites.
#
# SKIP_MODEL defaults to 1. Do NOT set it to 0 here: the 10 GB weight already
# sits on this box at ~/models/humanizer/, but baking it in means a ~12 GB
# image and a much longer build, and the volume path is the supported design.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/alvaropuche/humanizer-12b:latest}"
MIN_FREE_GB="${MIN_FREE_GB:-10}"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'build-on-vps: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is not installed on this host; install it or use GitHub Actions"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN (needs write:packages)}"

free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
say "free disk: ${free_gb} GB (need ${MIN_FREE_GB} GB)"
[ "$free_gb" -ge "$MIN_FREE_GB" ] || die "not enough free disk; refusing to start"

say "logging in to ghcr.io"
printf '%s' "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_USER:-alvaropuche}" --password-stdin

cd "$(dirname "$0")"
say "building ${IMAGE} (SKIP_MODEL=1)"
docker build --platform linux/amd64 --build-arg SKIP_MODEL=1 -t "$IMAGE" .
docker push "$IMAGE"

say "pushed ${IMAGE}"
say "now run deploy.sh with IMAGE=${IMAGE}"
