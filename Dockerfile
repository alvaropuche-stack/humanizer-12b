# Runpod serverless image for jialinyyzz/humanizer (Gemma-4 12B, Q6_K).
#
# NO BULK DOWNLOAD ON A LAPTOP. This image is meant to be built by Runpod's own
# builder, or on the Singapore VPS, never with `docker build` on a metered
# connection: the CUDA base plus the weights is many GB.
#
# Default build (SKIP_MODEL=1) keeps the image ~2.5 GB compressed: base, the
# pinned llama.cpp binary, the runpod SDK. The 10 GB GGUF lives on a Runpod
# network volume instead, and handler.py verifies its sha256 before use.
#
# Base choice: plain CUDA runtime, not runpod/worker-cuda12.4.
#   1. runpod/worker-cuda12.4 does not exist on Docker Hub (404). The official
#      runpod/base CUDA tags are ~6.6 GB compressed because they carry five
#      Python versions plus torch.
#   2. The prebuilt llama.cpp binaries need GLIBC_2.38, so Ubuntu 24.04
#      (glibc 2.39) is required; 22.04 has 2.35 and fails at load time.
#   3. This image needs only python3, curl, ca-certificates, libgomp1, libssl3.
#      nvidia/cuda:12.8.2-runtime-ubuntu24.04 is ~2.1 GB compressed and was
#      confirmed present on the registry (amd64 + arm64 manifests).
#
# llama.cpp is NOT compiled here. Compiling needs a full nvcc toolchain, a
# source checkout and far more build time, all of which fight Runpod's 30
# minute docker-build limit. The official prebuilt
# llama-b11785-bin-ubuntu-cuda-12.8-x64 tarball is downloaded and its sha256
# verified instead.

FROM nvidia/cuda:12.8.2-runtime-ubuntu24.04

# --- pinned llama.cpp prebuilt (CPU + CUDA) --------------------------------
ARG LLAMA_TARBALL=https://github.com/ggml-org/llama.cpp/releases/download/b11785/llama-b11785-bin-ubuntu-cuda-12.8-x64.tar.gz
ARG LLAMA_TARBALL_SHA256=a12d6aa5df1e2686092ed4af0dbd9e038c708eb8c42bcca21920f71c03a90c20

# --- optional baked weights ------------------------------------------------
# Default OFF: the weight belongs on a network volume. Set SKIP_MODEL=0 only if
# you deliberately want a ~12 GB image with the model inside it.
ARG MODEL_URL=https://huggingface.co/jialinyyzz/humanizer/resolve/main/humanizer-12b-Q6_K.gguf
ARG MODEL_SHA256=c98f03bb9e71456181f99b0e1d3391e07ce1afc357f9db4c33d6d379b8dd9f0d
ARG SKIP_MODEL=1

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    LD_LIBRARY_PATH=/opt/llama.cpp \
    HF_HUB_DISABLE_TELEMETRY=1 \
    HUMANIZER_LLAMA_BIN=/opt/llama.cpp/llama-server \
    HUMANIZER_MODEL="" \
    HUMANIZER_ALLOW_DOWNLOAD="0"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libgomp1 \
        libssl3t64 \
        python3 \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Prebuilt llama.cpp: binaries and shared objects land together in
# /opt/llama.cpp and resolve each other through the $ORIGIN rpath baked into
# the release, so LD_LIBRARY_PATH above is belt-and-braces.
RUN set -eux; \
    curl -fsSL --retry 2 -o /tmp/llama.tar.gz "$LLAMA_TARBALL"; \
    echo "${LLAMA_TARBALL_SHA256}  /tmp/llama.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/llama.cpp; \
    tar -xzf /tmp/llama.tar.gz -C /opt/llama.cpp --strip-components=1; \
    rm /tmp/llama.tar.gz; \
    test -x /opt/llama.cpp/llama-server; \
    test -f /opt/llama.cpp/libggml-cuda.so; \
    test -f /opt/llama.cpp/libllama-server-impl.so

RUN python3 -m pip install --no-cache-dir --break-system-packages runpod==1.12.0

# Optional weight bake + the mandatory hash gate. Off by default.
RUN set -eux; \
    mkdir -p /models; \
    if [ "$SKIP_MODEL" = "1" ]; then \
        echo "SKIP_MODEL=1: weights not baked; a network volume must provide them"; \
    else \
        curl -fL --retry 2 --retry-delay 5 -o /models/humanizer-12b-Q6_K.gguf "$MODEL_URL"; \
        echo "${MODEL_SHA256}  /models/humanizer-12b-Q6_K.gguf" | sha256sum -c -; \
        test "$(stat -c %s /models/humanizer-12b-Q6_K.gguf)" = "10029799584"; \
    fi

WORKDIR /app
COPY handler.py /app/handler.py

# Fail the build early if the inlined prompt contract drifts from the model
# card, instead of discovering it on the first paid request. check_contract.py
# reads the constants out of the source with ast, so it never imports
# handler.py (which would boot llama-server and need a GPU).
COPY check_contract.py /app/check_contract.py
RUN cd /app && python3 check_contract.py handler.py

CMD ["python3", "-u", "handler.py"]
