# .sandy/Dockerfile — GPU support for sandy
#
# Copy this file to your project's .sandy/Dockerfile:
#   cp examples/gpu/Dockerfile .sandy/Dockerfile
#
# Then enable GPU passthrough in .sandy/config:
#   SANDY_GPU=all
#
# Requires NVIDIA Container Toolkit on the host:
#   https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
#
# Works on x86_64 and arm64 (including DGX Spark).

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# --- Option 1: Full CUDA toolkit (needed for compiling CUDA code) ---
# Adds ~3-5GB. Use this if you need nvcc, cuDNN headers, or are building
# custom CUDA kernels.
#
# The repo's Debian release must match sandy's base image, which is Debian 13
# (trixie). NVIDIA's debian12 repo does not work on it: its signing key relies
# on a SHA-1 binding signature, which trixie's apt (sqv) has rejected since
# 2026-02-01, so `apt-get update` fails with "The repository ... is not signed".

RUN CUDA_ARCH="$(uname -m)"; [ "$CUDA_ARCH" = "aarch64" ] && CUDA_ARCH="sbsa"; \
    curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/debian13/${CUDA_ARCH}/cuda-keyring_1.1-1_all.deb" \
        -o /tmp/cuda-keyring.deb \
    && dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends cuda-toolkit \
    && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/local/cuda/bin:${PATH}

# --- Option 2: PyTorch only (lighter, no system CUDA needed) ---
# Uncomment below and comment out Option 1 if you just need PyTorch.
# Pre-built wheels include their own CUDA runtime (~2GB download).

# RUN pip install --no-cache-dir --break-system-packages torch torchvision torchaudio

# --- Python ML packages (baked into the project image) ---
# Build steps run as root, so install system-wide: `pip install --user` here
# would land in /root/.local, which the agent (user sandy) cannot see. A
# `pip install` run inside a session is different: it persists across
# sessions via the per-project pip sandbox.
# Uncomment what you need:

# RUN pip install --no-cache-dir --break-system-packages transformers accelerate
# RUN pip install --no-cache-dir --break-system-packages jupyter
# RUN pip install --no-cache-dir --break-system-packages numpy pandas scikit-learn
