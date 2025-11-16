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

# Install system dependencies including git-lfs
RUN apt-get update && apt-get install -y \
    python3.12 python3.12-venv git git-lfs wget \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
    ffmpeg \
    espeak-ng libespeak-ng1 \
    build-essential \
 && git lfs install \
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

# Optional: upgrade torch stack
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./
WORKDIR /

# Runtime deps for handler + snapshot_download
RUN uv pip install runpod requests websocket-client huggingface-hub

# App code & scripts
ADD src/start.sh handler.py test_input.json ./
RUN chmod +x /start.sh

# Helper scripts
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

ENV PIP_NO_INPUT=1
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

COPY --from=downloader /comfyui/models /comfyui/models

run comfy-node-install https://github.com/city96/ComfyUI-GGUF
# Install both nodes with appropriate Git LFS handling
RUN comfy-node-install https://github.com/Enemyx-net/VibeVoice-ComfyUI && \
    GIT_LFS_SKIP_SMUDGE=1 comfy-node-install https://github.com/snicolast/ComfyUI-IndexTTS2

# Install IndexTTS2 dependencies with Git LFS skip to avoid audiotools test file issues
RUN uv pip install wetext && \
    GIT_LFS_SKIP_SMUDGE=1 uv pip install -r /comfyui/custom_nodes/ComfyUI-IndexTTS2/requirements.txt

# Clone IndexTTS-2 model files into the exact checkpoints path
RUN git lfs install && \
    git clone https://huggingface.co/IndexTeam/IndexTTS-2 /opt/IndexTTS-2 && \
    mkdir -p /comfyui/custom_nodes/ComfyUI-IndexTTS2/checkpoints && \
    cp -r /opt/IndexTTS-2/* /comfyui/custom_nodes/ComfyUI-IndexTTS2/checkpoints/ && \
    test -f /comfyui/custom_nodes/ComfyUI-IndexTTS2/checkpoints/config.yaml

# W2V-BERT encoder
RUN python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download(
    "facebook/w2v-bert-2.0",
    local_dir="/comfyui/custom_nodes/ComfyUI-IndexTTS2/checkpoints/w2v-bert-2.0",
    local_dir_use_symlinks=False
)
PY

# BigVGAN vocoder (22kHz)
RUN mkdir -p /comfyui/custom_nodes/ComfyUI-IndexTTS2/checkpoints/bigvgan && \
    wget -qO /comfyui/custom_nodes/ComfyUI-IndexTTS2/checkpoints/bigvgan/config.json \
      https://huggingface.co/nvidia/bigvgan_v2_22khz_80band_256x/resolve/main/config.json && \
    wget -qO /comfyui/custom_nodes/ComfyUI-IndexTTS2/checkpoints/bigvgan/bigvgan_generator.pt \
      https://huggingface.co/nvidia/bigvgan_v2_22khz_80band_256x/resolve/main/bigvgan_generator.pt

# Input convenience
COPY Input/ /comfyui/input/
