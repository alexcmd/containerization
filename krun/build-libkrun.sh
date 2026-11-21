#!/bin/sh
# Builds libkrun v1.19.8 with krun/patches/libkrun-venus-display.patch applied
# and installs it into PREFIX for `make krun-vmm KRUN_PREFIX=PREFIX`.
#
# The patch fixes two guest desktop freezes (global fences rejected by a
# Venus-only virglrenderer were never retired; the cursor queue was never
# drained) and adds krun_display_resize() so the guest follows the window size.
#
# Usage: krun/build-libkrun.sh SRC_DIR PREFIX VIRGL_PREFIX
#   SRC_DIR       clone of https://github.com/containers/libkrun (created if missing)
#   PREFIX        install prefix
#   VIRGL_PREFIX  prefix holding a Venus-enabled virglrenderer (lib/pkgconfig)
# Needs zig (`brew install zig`) to cross-compile the guest-side init.
set -eu

[ $# -eq 3 ] || { echo "usage: $0 SRC_DIR PREFIX VIRGL_PREFIX" >&2; exit 2; }
SRC=$1 PREFIX=$2 VIRGL=$3
PATCH=$(cd "$(dirname "$0")" && pwd)/patches/libkrun-venus-display.patch
TAG=v1.19.8

[ -d "$SRC/.git" ] || git clone --branch "$TAG" https://github.com/containers/libkrun "$SRC"
cd "$SRC"
if git apply --check "$PATCH" 2>/dev/null; then
    git apply "$PATCH"
elif ! git apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "error: $PATCH does not apply to $SRC" >&2
    exit 1
fi

FEATURES="BLK=1 NET=1 GPU=1 TIMESYNC=1 INPUT=1"
mkdir -p .empty
# shellcheck disable=SC2086
PKG_CONFIG_PATH="$VIRGL/lib/pkgconfig" make $FEATURES \
    "CC_LINUX=$(brew --prefix zig)/bin/zig cc -target aarch64-linux-musl" \
    SYSROOT_LINUX="$PWD/.empty"
# shellcheck disable=SC2086
make PREFIX="$PREFIX" $FEATURES install

# krun-vmm finds libkrun through its rpath; the default install name is a bare
# filename, which dyld cannot resolve.
for lib in "$PREFIX"/lib/libkrun.*.*.*.dylib; do
    install_name_tool -id @rpath/libkrun.1.dylib "$lib"
    codesign --force --sign - "$lib"
done
echo "Installed patched libkrun into $PREFIX"
