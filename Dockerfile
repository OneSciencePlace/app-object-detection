FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

# opencv-python (pulled in by ultralytics) links against libGL.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# CPU-only torch, installed before ultralytics so that ultralytics finds its
# torch/torchvision requirement already satisfied. PyPI's default torch wheel
# for Linux is the CUDA build: ~2.5 GB in the image.
#
# For a GPU demo, delete this step and change the base image to
#   FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04
# plus a python3 install -- pip will then pull the CUDA build of torch as an
# ordinary dependency of ultralytics.
RUN pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        torch==2.13.0 torchvision==0.28.0

# Everything else is installed at build time too. Nothing may be fetched at
# run time: a .sif is read-only and compute nodes are often offline.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# A .sif is mounted read-only, so send every library scratch path to /tmp and
# bake the model weights in at a fixed absolute path (/app/yolo11n.pt).
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    YOLO_CONFIG_DIR=/tmp/Ultralytics \
    MPLCONFIGDIR=/tmp/matplotlib \
    APP_MODEL=/app/yolo11n.pt

# Swap for yolo26n.pt (newest generation) or a larger size (s/m/l/x) freely --
# the API is identical, only the weights file changes.
RUN python -c "from ultralytics import YOLO; YOLO('yolo11n.pt')"

COPY run.py entrypoint.sh /app/
# Explicit modes. COPY preserves the build context's permissions, so a checkout
# made under a restrictive umask yields 0600/0700 files that the runtime user --
# `docker run --user`, or any user at all under Apptainer -- cannot even read.
# Git only tracks the exec bit, so this is not something the repo can guarantee.
RUN chmod -R a+rX /app && chmod 0755 /app/entrypoint.sh

# Tapis stages job inputs/outputs into the container's working directory.
# Docker honours this; Apptainer ignores it and uses the caller's directory.
# Either way run.py works off relative paths.
# /data is a mount point. Make it writable by whoever runs the container, so a
# run without a bind mount still works for a non-root user.
RUN mkdir -p /data && chmod 1777 /data

WORKDIR /data

ENTRYPOINT ["/app/entrypoint.sh"]
# Args are appended after the entrypoint, e.g.:
#   --image photo.jpg --conf 0.4
