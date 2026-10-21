#!/usr/bin/env python3
"""Runpod serverless handler for jialinyyzz/humanizer (Gemma-4 12B finetune).

Text-completion model, not a chat model. Prompt contract, byte for byte:

    prompt = instr + "\\n\\n" + draft.strip() + sep

instr and sep are hardcoded below so a request needs no second network fetch.
The sha256[:16] of the contract probe (draft == "X") is re-checked at import
time: a silent edit to either constant makes the container fail loudly instead
of quietly emitting worse prose.

Weights load ONCE at module import: llama-server is started here, not per
request, and every job is a plain POST to its /completion endpoint.

Weight lookup order (first hit wins):
  1. $HUMANIZER_MODEL, an explicit path.
  2. /runpod-volume/humanizer-12b-Q6_K.gguf  -- a network volume, the durable
     home for a 10 GB file; survives image rebuilds.
  3. /models/humanizer-12b-Q6_K.gguf         -- baked into the image, only used
     when the image was built without SKIP_MODEL.
  4. With HUMANIZER_ALLOW_DOWNLOAD=1, fetch into the network volume from HF,
     verifying sha256 before it is ever passed to llama-server. This runs on
     Runpod's network, never on a laptop.
"""

import hashlib
import json
import logging
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

LOG = logging.getLogger("humanizer")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    stream=sys.stdout,
)

# --- prompt contract -------------------------------------------------------
# Must match ~/models/humanizer/prompt_format.json (HF: prompt_format.json).
INSTR = """Rewrite the text below so it reads like a person wrote it, not a language model.

Reorganize it as you see fit. Vary sentence length on purpose. Cut hedging,
throat-clearing, and any sentence that only announces what comes next.
Prefer the concrete word over the abstract one. It is fine to sound uneven.

Every fact, number, unit, date, name and quotation must survive unchanged."""
SEP = "\n\n### Rewritten:\n\n"
EXPECTED_HASH = "cc51d66b4c593fbe"

# --- model identity --------------------------------------------------------
MODEL_FILENAME = "humanizer-12b-Q6_K.gguf"
MODEL_SHA256 = "c98f03bb9e71456181f99b0e1d3391e07ce1afc357f9db4c33d6d379b8dd9f0d"
MODEL_BYTES = 10029799584
MODEL_URL = ("https://huggingface.co/jialinyyzz/humanizer/resolve/main/"
             + MODEL_FILENAME)

# --- runtime paths ---------------------------------------------------------
VOLUME_DIR = "/runpod-volume"
VOLUME_MODEL = os.path.join(VOLUME_DIR, MODEL_FILENAME)
BAKED_MODEL = os.path.join("/models", MODEL_FILENAME)
LLAMA_BIN = os.environ.get("HUMANIZER_LLAMA_BIN", "/opt/llama.cpp/llama-server")
LLAMA_HOST = "127.0.0.1"
LLAMA_PORT = int(os.environ.get("HUMANIZER_PORT", "8090"))
COMPLETION_URL = "http://%s:%d/completion" % (LLAMA_HOST, LLAMA_PORT)
HEALTH_URL = "http://%s:%d/health" % (LLAMA_HOST, LLAMA_PORT)
SERVER_LOG = os.environ.get("HUMANIZER_SERVER_LOG", "/tmp/llama-server.log")
STARTUP_TIMEOUT = int(os.environ.get("HUMANIZER_STARTUP_TIMEOUT", "900"))
REQUEST_TIMEOUT = int(os.environ.get("HUMANIZER_REQUEST_TIMEOUT", "600"))

# --- sampling --------------------------------------------------------------
# Fixed on purpose: the model card's values. No stop strings, ever -- "###"
# would truncate real rewrites mid-answer.
SAMPLING = {
    "temperature": 1.0,
    "top_p": 0.95,
    "top_k": 0,
    "min_p": 0.0,
    "repeat_penalty": 1.0,
    "n_predict": 2048,
    "n_probs": 0,
    "stream": False,
    "stop": [],
}


def prompt_hash() -> str:
    return hashlib.sha256((INSTR + "\n\n" + "X" + SEP).encode()).hexdigest()[:16]


def assert_contract() -> str:
    got = prompt_hash()
    if got != EXPECTED_HASH:
        raise RuntimeError(
            "prompt contract drift: sha256(probe)[:16] is %s, expected %s. "
            "INSTR/SEP in handler.py no longer match prompt_format.json; fix the "
            "constants before serving (a silent change degrades every rewrite)."
            % (got, EXPECTED_HASH)
        )
    return got


CONTRACT_HASH = assert_contract()


def log_tail(path: str, lines: int = 40) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return "".join(fh.readlines()[-lines:]).strip()
    except OSError as exc:
        return "<no log at %s: %s>" % (path, exc)


# --- weights ---------------------------------------------------------------
def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(path: str) -> str:
    size = os.path.getsize(path)
    if size != MODEL_BYTES:
        raise RuntimeError(
            "%s is %d bytes, expected %d -- truncated or wrong file"
            % (path, size, MODEL_BYTES)
        )
    got = sha256_file(path)
    if got != MODEL_SHA256:
        raise RuntimeError(
            "%s sha256 is %s, expected %s -- refusing to serve unverified "
            "weights" % (path, got, MODEL_SHA256)
        )
    LOG.info("weights verified: %s (sha256 %s…)", path, got[:16])
    return path


def download_into_volume() -> str:
    """Fetch the GGUF into the network volume, verifying before use.

    Runs on Runpod's network. The partial file is written under a .part name
    and only renamed after the hash matches, so a killed worker can never leave
    a half file that looks complete.
    """
    if not os.path.isdir(VOLUME_DIR):
        raise RuntimeError(
            "%s is not mounted, so the weights cannot be cached there. Attach a "
            "network volume or build the image with the weights." % VOLUME_DIR
        )
    tmp = VOLUME_MODEL + ".part"
    LOG.info("downloading %s -> %s", MODEL_URL, VOLUME_MODEL)
    req = urllib.request.Request(MODEL_URL, headers={"User-Agent": "runpod-humanizer/1"})
    with urllib.request.urlopen(req, timeout=60) as resp, open(tmp, "wb") as out:
        expected = resp.headers.get("Content-Length")
        written = 0
        while True:
            chunk = resp.read(8 * 1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
            written += len(chunk)
            if written % (1024 * 1024 * 1024) < 8 * 1024 * 1024:
                LOG.info("downloaded %.1f GB%s", written / 1e9,
                         " of %s" % expected if expected else "")
    try:
        verify(tmp)
    except Exception:
        os.unlink(tmp)
        raise
    os.replace(tmp, VOLUME_MODEL)
    LOG.info("weights cached in the network volume")
    return VOLUME_MODEL


def ensure_weights() -> str:
    override = os.environ.get("HUMANIZER_MODEL")
    if override:
        return verify(override)
    if os.path.isfile(VOLUME_MODEL):
        try:
            return verify(VOLUME_MODEL)
        except RuntimeError as exc:
            LOG.error("volume copy is bad (%s); treating it as absent", exc)
            os.unlink(VOLUME_MODEL)
    if os.path.isfile(BAKED_MODEL):
        return verify(BAKED_MODEL)
    if os.environ.get("HUMANIZER_ALLOW_DOWNLOAD") == "1":
        return download_into_volume()
    raise RuntimeError(
        "no usable weights. Looked for %s (network volume) and %s (baked in). "
        "Attach a seeded network volume, set HUMANIZER_ALLOW_DOWNLOAD=1 to fetch "
        "them into the volume once, or bake them in at build time."
        % (VOLUME_MODEL, BAKED_MODEL)
    )


# --- llama-server ----------------------------------------------------------
def wait_for_health(proc: subprocess.Popen, timeout: int) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(
                "llama-server exited with code %s before becoming healthy.\n"
                "--- log tail ---\n%s" % (proc.returncode, log_tail(SERVER_LOG))
            )
        try:
            with urllib.request.urlopen(HEALTH_URL, timeout=3) as resp:
                if resp.status == 200:
                    LOG.info("llama-server healthy on %s:%d", LLAMA_HOST, LLAMA_PORT)
                    return
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(1)
    proc.kill()
    raise RuntimeError(
        "llama-server did not become healthy within %ss.\n--- log tail ---\n%s"
        % (timeout, log_tail(SERVER_LOG))
    )


def start_server() -> str:
    """Load the weights once for the lifetime of this worker."""
    weight = ensure_weights()
    LOG.info("loading %s (%.2f GB) with %s",
             weight, os.path.getsize(weight) / 1e9, LLAMA_BIN)
    log_fh = open(SERVER_LOG, "wb")
    proc = subprocess.Popen(
        [
            LLAMA_BIN,
            "-m", weight,
            "-c", "8192",
            "-np", "1",
            "-ngl", "99",
            "--host", LLAMA_HOST,
            "--port", str(LLAMA_PORT),
        ],
        stdout=log_fh,
        stderr=subprocess.STDOUT,
    )
    LOG.info("llama-server pid %s; waiting for /health", proc.pid)
    wait_for_health(proc, STARTUP_TIMEOUT)
    return weight


WEIGHT_PATH = start_server()


# --- rewriting -------------------------------------------------------------
def cjk_ratio(text: str) -> float:
    cjk = sum(1 for ch in text if "\u4e00" <= ch <= "\u9fff")
    return cjk / max(1, len(text))


def looks_latin(text: str) -> bool:
    latin = sum(1 for ch in text if ch.isascii() and ch.isalpha())
    cjk = sum(1 for ch in text if "\u4e00" <= ch <= "\u9fff")
    return latin > cjk


def complete(prompt: str) -> dict:
    payload = dict(SAMPLING, prompt=prompt)
    req = urllib.request.Request(
        COMPLETION_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def rewrite(draft: str) -> dict:
    prompt = INSTR + "\n\n" + draft.strip() + SEP
    body = complete(prompt)
    text = body.get("content")
    if not isinstance(text, str):
        raise ValueError("unexpected /completion shape: %s" % json.dumps(body)[:300])

    # Known failure mode: the model sometimes answers a short English draft in
    # Chinese. One resample, as the model card advises.
    if looks_latin(draft.strip()) and cjk_ratio(text) > 0.05:
        LOG.warning("rewrite drifted into Chinese; resampling once")
        body = complete(prompt)
        text = body.get("content") or ""
        if cjk_ratio(text) > 0.05:
            LOG.warning("rewrite is still partly Chinese")

    text = text.strip()
    return {
        "rewritten": text,
        "prompt_sha16": CONTRACT_HASH,
        "truncated": bool(body.get("truncated")),
        "chars_in": len(draft),
        "chars_out": len(text),
    }


def handler(job):
    inp = job.get("input") if isinstance(job, dict) else None
    if not isinstance(inp, dict):
        return {"error": "job.input must be an object like {\"draft\": \"...\"}",
                "prompt_sha16": CONTRACT_HASH}
    draft = inp.get("draft")
    if not isinstance(draft, str) or not draft.strip():
        return {"error": "job.input.draft must be a non-empty string",
                "prompt_sha16": CONTRACT_HASH}
    if len(draft) > 24000:
        LOG.warning("draft is %d chars; 8192 context holds ~20-25k chars", len(draft))
    try:
        return rewrite(draft)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        return {"error": "llama-server returned HTTP %s: %s" % (exc.code, detail),
                "prompt_sha16": CONTRACT_HASH}
    except urllib.error.URLError as exc:
        return {"error": "cannot reach llama-server at %s (%s); see %s"
                         % (COMPLETION_URL, exc.reason, SERVER_LOG),
                "prompt_sha16": CONTRACT_HASH}
    except ValueError as exc:
        return {"error": "bad response from llama-server: %s" % exc,
                "prompt_sha16": CONTRACT_HASH}
    except OSError as exc:  # socket timeouts
        return {"error": "llama-server timed out after %ss: %s"
                         % (REQUEST_TIMEOUT, exc),
                "prompt_sha16": CONTRACT_HASH}


if __name__ == "__main__":
    import runpod

    runpod.serverless.start({"handler": handler})
