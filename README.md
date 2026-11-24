
# PCSX2 0.9.8 for OpenGL 2.1 Hardware

Build scripts and compatibility patches to compile **PCSX2 0.9.8** (32-bit x86) inside a Debian Wheezy (`i386`) container and bundle it into a portable `AppDir` for modern Linux systems with older OpenGL 2.1 GPUs.

Tested on hardware such as **Intel Core 2 Duo P8600 + GMA 4500**, software is **Arch Linux x86_64** with lastest kernel, glibc, wayland/xwayland, etc.

<p align="center">
<img src="kofxi.webp" alt="Kof XI" width="48%" />
<img src="twinsanity.webp" alt="Twinsanity" width="48%" />
</p>

## Why This Exists

Modern PCSX2 versions require newer OpenGL capabilities and modern toolchains, while legacy 32-bit releases depend on older libraries that are awkward to piece together oReleases page, you can use `--appimage-extract` for a tarball-like setun current distros. This project provides a reproducible build environment and targeted source patches without bundling PCSX2's own source code.

This is obviously mostly aiming to play PS2 2D or very light 3D games because most GL2 class would have a very poor 3D performance.

## Downloads

pre-built AppImages are available on p.

## Requirements

### Build host
- `docker` (with `buildx` / multi-arch or `i386` emulation support as needed on your host)

### Runtime dependencies (Arch Linux, 32-bit)
```sh
sudo pacman -S --needed \
  lib32-mesa lib32-libx11 lib32-libxext lib32-libxxf86vm \
  lib32-alsa-lib lib32-libpulse lib32-libdrm lib32-libxdamage lib32-libxfixes
```

## Usage

### 1. Build the container image

```sh
docker build -t pcsx2-098 .
```

### 2. Build `PCSX2.AppDir`

```sh
mkdir -p out src-pcsx2
docker run --rm \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$PWD/out:/out" \
  -v "$PWD/src-pcsx2:/src/pcsx2" \
  pcsx2-098
```

The resulting bundle is written to `./out/PCSX2.AppDir` (and can be run via `./out/PCSX2.AppDir/AppRun` or packaged into an `.AppImage` with `appimagetool`).

### 3. Debug build (`Devel`)

Includes debug symbols and assertions:

```sh
docker run --rm \
  -e BUILD_TYPE=Devel \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$PWD/out:/out" \
  -v "$PWD/src-pcsx2:/src/pcsx2" \
  pcsx2-098
```

To run with an automatic backtrace on crash:

```sh
PCSX2_GDB=1 ./out/PCSX2.AppDir/AppRun
```

## Disclaimer

This repository contains only build scripts, runtime wrappers, and source patches. It does not distribute PCSX2 source code, binaries, or PlayStation 2 BIOS files.
