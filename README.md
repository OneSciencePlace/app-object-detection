# app-object-detection

A deliberately small example of the whole pipeline we use for `app-*` repos:

```
Dockerfile  ->  GitHub Actions  ->  ghcr.io/onescienceplace/app-object-detection       (OCI image)
                                ->  ghcr.io/onescienceplace/app-object-detection-sif   (Apptainer .sif)
```

The app itself runs YOLO11 over an image and writes an annotated JPEG plus a
`detections.json`. The app is not the point — the build/host mechanism is.

## Contents

| File | Purpose |
|---|---|
| `Dockerfile` | The image. Model weights are baked in at `/app/yolo11n.pt`. |
| `requirements.txt` | Pinned Python deps. (Python's manifest — other apps use their own.) |
| `run.py` | The program. Reads/writes relative to the current working directory. |
| `entrypoint.sh` | The image ENTRYPOINT. `exec`s `run.py` with `"$@"`. |
| `.github/workflows/build-and-push.yml` | Build + push both artifacts. App-agnostic — copy as-is. |

`entrypoint.sh` is what keeps this repo the same shape as every other `app-*`
repo: swap its last line for `Rscript`, `node`, a compiled binary, or a vendor
tool and nothing else about the pipeline changes.

## What the workflow does

Triggered by pushes to `main`, `v*` tags, and manual dispatch — nothing else.

1. **`docker` job** — builds the Dockerfile and pushes to GHCR, tagged
   `latest` (on `main`), `sha-<short>`, and `<version>` on a `v*` git tag.
2. **`sif` job** — installs Apptainer from its upstream release `.deb`,
   pulls the image it just pushed,
   converts it with `apptainer build`, and pushes the `.sif` to GHCR as an
   ORAS artifact under the `-sif` package name, using the same tag.

Both jobs use the automatic `GITHUB_TOKEN`; no secrets to configure. The repo
needs **Settings → Actions → Workflow permissions → Read and write**, or the
`permissions:` blocks already in the workflow.

## Using the results

```bash
# Docker
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD:/data" ghcr.io/onescienceplace/app-object-detection:latest \
  --image photo.jpg --conf 0.4

# Apptainer / Singularity (HPC)
apptainer pull oras://ghcr.io/onescienceplace/app-object-detection-sif:latest
apptainer run app-object-detection-sif_latest.sif --image photo.jpg --conf 0.4
```

Apptainer runs with your host working directory as the CWD and the container
filesystem read-only, which is why the weights live at an absolute path and
`HOME` / `XDG_CACHE_HOME` / `YOLO_CONFIG_DIR` / `MPLCONFIGDIR` all point at
`/tmp`.

## Pinned versions

| What | Version | Where |
|---|---|---|
| Base image | `python:3.14-slim` | `Dockerfile` |
| Ultralytics | `8.4.131` | `requirements.txt` |
| torch / torchvision | `2.13.0` / `0.28.0`, CPU-only | `Dockerfile` |
| Model weights | `yolo11n.pt` | baked in at build time |
| Apptainer | `1.5.2` | `APPTAINER_VERSION` in the workflow |
| Actions | checkout v6, buildx v4, login v4, metadata v6, build-push v7 | the workflow |

Actions are pinned to a major tag, so patch and minor updates arrive on their
own; a major bump is a deliberate edit. Apptainer is installed from its
release `.deb` rather than a marketplace action — the `.deb` carries the
AppArmor profile that permits unprivileged user namespaces on Ubuntu 24.04+,
and a plain `run:` step can't be deprecated by a GitHub Node.js runtime change.

The image is CPU-only on purpose: PyPI's default torch wheel is the CUDA
build, which adds roughly 2 GB the `.sif` then carries. The Dockerfile installs
torch from PyTorch's CPU index first; the GPU route is one commented block away.

## Build and test locally

Skip GitHub and the registry entirely:

```bash
docker build -t app-object-detection:dev .   # --platform linux/amd64 on Apple Silicon
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD:/data" app-object-detection:dev --image photo.jpg --conf 0.4

docker save app-object-detection:dev -o aod.tar
apptainer build aod.sif docker-archive://aod.tar
apptainer run aod.sif --image photo.jpg --conf 0.4
```

### Why `--user`

Docker runs the container as root, so anything it writes into the bind-mounted
directory lands on your disk owned by `root` and needs `sudo` to delete.
`--user "$(id -u):$(id -g)"` makes the container write as you, and matches how
Apptainer runs it — Apptainer is always the invoking user, so it never has this
problem.

To reclaim files a previous root-owned run left behind:

```bash
sudo chown -R "$(id -u):$(id -g)" .
```

The one visible side effect: that uid has no `/etc/passwd` entry inside the
container, so `whoami` fails and `ls -l` shows bare numbers. Nothing actually
breaks — only code calling `getpwuid()` notices — and Apptainer generates the
entry itself, so this never shows up in production. If you want a name locally,
show the container your real identity:

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro ...
```

`apptainer build` from a local archive needs no root and no fakeroot. Test the
`.sif` and not just the image: read-only-filesystem bugs never show up under
`docker run`.
