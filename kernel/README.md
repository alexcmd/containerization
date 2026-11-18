# Containerization Kernel Configuration

This directory includes an optimized kernel configuration to produce a fast and lightweight kernel for container use.

- `config-arm64` and `config-x86_64` include the per-arch kernel `CONFIG_` options.
- `Makefile` includes the kernel version and source package URL.
- `build.sh` scripts the kernel build process.
- `image/` includes the configuration for an image with build tooling.

## Kernel version

The kernel must be Linux 7.2 or newer. The libkrun backend's Venus GPU device
(`KrunGPUMode.venus`) needs the virtio-gpu driver to negotiate
`VIRTIO_GPU_F_BLOB_ALIGNMENT`, which first shipped in 7.2. macOS hosts map
host-visible blobs at 16 KiB, so on an older kernel a 4 KiB-page guest maps
Venus's ring at the wrong alignment and `vkCreateInstance` fails with
`VK_ERROR_OUT_OF_HOST_MEMORY`. The Virtualization.framework path itself has no
such requirement.

## Building

1. The build process relies on having the `container` tool installed (https://github.com/apple/container/releases).
2. Run `make`. This should create the image used for building the resulting Linux kernel, and then run a container with that image to perform the kernel build.

### Target architecture

The build target is selected by the `TARGET_ARCH` make variable, which accepts either `arm64` or `x86_64`. When unset, it falls back to the build host's architecture (as reported by `uname -m`, with `aarch64`/`amd64` normalized to `arm64`/`x86_64`).

- `make` (default) → builds for the host arch
- `make TARGET_ARCH=arm64` → `vmlinux-arm64` (uncompressed `Image`)
- `make TARGET_ARCH=x86_64` → `vmlinuz-x86_64` (compressed `bzImage`, cross-compiled inside the arm64 container)
- `make x86_64` → convenience alias for `make TARGET_ARCH=x86_64`

The `z` suffix on the x86 name follows Linux convention for a compressed kernel image. The resulting kernel is copied into the repo's `bin/` directory.
