# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

# ----------------------
# Stage 1: Base
# ----------------------
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Core OS deps + audio/video + (optional) phonemizer backend
RUN apt-get update && apt-get install -y \
    python3.12 python3.12-venv git wget \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
    ffmpeg \
    espeak-ng libespeak-ng1 \
 && ln -sf /usr/bin/python3.12 /usr/bin/python \
 && ln -sf /usr/bin/pip3 /usr/bin/pip \
 && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# uv + venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
 && ln -s /root/.local/bin/uv /usr/local/bin/uv \
 && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
 && uv venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# comfy-cli to install ComfyUI
RUN uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI (nvidia build)
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Optional: upgrade torch stack for your CUDA if needed
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

# Place extra model paths
WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./

# Back to root
WORKDIR /

# Runtime deps for handler
RUN uv pip install runpod requests websocket-client

# App code & scripts
ADD src/start.sh handler.py test_input.json ./
RUN chmod +x /start.sh

# Helper scripts
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

ENV PIP_NO_INPUT=1

COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

CMD ["/start.sh"]

# ----------------------
# Stage 2: Downloader
# ----------------------
FROM base AS downloader
WORKDIR /comfyui
RUN mkdir -p models/checkpoints models/vae models/unet models/clip

# ----------------------
# Stage 3: Final
# ----------------------
FROM base AS final

# Models (if any) copied from downloader stage
COPY --from=downloader /comfyui/models /comfyui/models

# Install VibeVoice and IndexTTS2 nodes
RUN comfy-node-install https://github.com/Enemyx-net/VibeVoice-ComfyUI && \
    comfy-node-install https://github.com/snicolast/ComfyUI-IndexTTS2

# 🔧 IndexTTS2 Python deps (per README)
# - wetext
# - the node's requirements.txt
RUN uv pip install wetext && \
    uv pip install -r /comfyui/custom_nodes/ComfyUI-IndexTTS2/requirements.txt

# Input convenience
COPY Input/ /comfyui/input/
