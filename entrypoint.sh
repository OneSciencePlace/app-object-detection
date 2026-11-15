#!/bin/sh
# entrypoint.sh - the one contract every app-* image honours: pass "$@"
# through to the real program, exec'd so it becomes PID 1.
#
# This app happens to be Python; another app-* repo swaps the last line for a
# compiled binary, Rscript, node, or a vendor tool, and nothing else changes.

set -eu

# Scratch directory. The scheduler usually hands us a TMPDIR pointing at a host
# path like /scratch/$USER/job.12345 -- and Apptainer binds $HOME, /tmp and $PWD
# by default, NOT necessarily /scratch. Inside the container that path does not
# exist and the root filesystem is read-only, so `mkdir -p "$TMPDIR"` dies with
# "cannot create directory '/scratch': Read-only file system". Try the
# candidates in order and use the first one we can actually write to. Under the
# OSP batch run profile the app definition sets TMPDIR=<job directory>/tmp,
# which is bound and writable. Never bind a scratch *parent* (`--bind /scratch`)
# to make an inherited TMPDIR work: it exposes every other job's directory to
# the same uid.
_pick_tmpdir() {
    for _d in "${TMPDIR:-}" /tmp "${HOME:-}"; do
        [ -n "$_d" ] || continue
        mkdir -p "$_d" 2>/dev/null || continue
        [ -w "$_d" ] || continue
        printf '%s' "$_d"
        return 0
    done
    return 1
}
_tmpdir_was="${TMPDIR:-}"
TMPDIR="$(_pick_tmpdir)" || {
    echo "[app] no writable scratch directory (tried TMPDIR, /tmp, HOME)" >&2
    exit 1
}
export TMPDIR
if [ -n "$_tmpdir_was" ] && [ "$_tmpdir_was" != "$TMPDIR" ]; then
    echo "[app] TMPDIR=$_tmpdir_was is not writable in this container; using $TMPDIR" >&2
fi

# HOME and the caches. The image points them at fixed paths in /tmp
# (Dockerfile ENV) so that something is writable under a read-only .sif. Under
# the batch run profile /tmp is the job's own and they do no harm. Without it
# /tmp is the node's, and a fixed /tmp/.cache or /tmp/Ultralytics belongs to
# whichever user ran first: every later user's writes there fail. Where those
# defaults are still in effect, this run gets its own, as interactive sessions
# do (web/session-env.sh in app-template): the home in a fresh 0700 directory
# under /tmp, the caches -- which hold nothing secret and may grow -- in one of
# the same name under $TMPDIR. A value the job set itself is kept.
_run=""
_run_dir() {
    [ -n "$_run" ] || _run="$(mktemp -d /tmp/osp-run-XXXXXXXX)" || {
        echo "[app] cannot create a run directory under /tmp" >&2
        exit 1
    }
}
if [ "${HOME:-/tmp}" = /tmp ]; then
    _run_dir
    HOME="$_run/home"
    mkdir -p "$HOME"
fi
_cache_dir() {   # $1: subdirectory name; _run_dir first (not in a subshell)
    _c="$TMPDIR/${_run##*/}/$1"
    mkdir -p "$_c" 2>/dev/null || { _c="$_run/$1"; mkdir -p "$_c"; }
    printf '%s' "$_c"
}
if [ -z "${XDG_CACHE_HOME:-}" ] || [ "$XDG_CACHE_HOME" = /tmp/.cache ]; then
    _run_dir
    XDG_CACHE_HOME="$(_cache_dir cache)"
fi
if [ "${YOLO_CONFIG_DIR:-/tmp/Ultralytics}" = /tmp/Ultralytics ]; then
    _run_dir
    YOLO_CONFIG_DIR="$(_cache_dir Ultralytics)"
fi
if [ "${MPLCONFIGDIR:-/tmp/matplotlib}" = /tmp/matplotlib ]; then
    _run_dir
    MPLCONFIGDIR="$(_cache_dir matplotlib)"
fi
export HOME XDG_CACHE_HOME YOLO_CONFIG_DIR MPLCONFIGDIR

exec python3 /app/run.py "$@"
