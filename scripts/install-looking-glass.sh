#!/usr/bin/env bash
# install-looking-glass.sh — build and install the Looking Glass client on
# Omarchy from source. Building from source lets you match the client
# version exactly to the guest host-app version.
#
# Usage:
#     scripts/install-looking-glass.sh                 # default version (see below)
#     scripts/install-looking-glass.sh B7-rc1          # specific release
#     scripts/install-looking-glass.sh B7-rc1 /opt     # install prefix
#
# The default VERSION below tracks a known-good release at the time
# this script was last touched — bump it (or override on the command
# line) to whatever is current at <https://looking-glass.io/downloads>.
# The guest host-app and the host client MUST match versions exactly;
# their shared-memory protocol is not forward-compatible.

set -euo pipefail

VERSION="${1:-B7}"
PREFIX="${2:-/usr/local}"

BUILD_DIR="${TMPDIR:-/tmp}/looking-glass-build.$$"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "==> Installing build dependencies (Arch)"
sudo pacman -S --needed --noconfirm \
    base-devel cmake fontconfig spice-protocol \
    nettle libxkbcommon wayland-protocols libdecor \
    libxpresent libxi libxinerama libxcursor libxrandr sdl2

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "==> Downloading Looking Glass $VERSION"
curl -fSL "https://looking-glass.io/artifact/$VERSION/source" -o lg.tar.gz
tar xf lg.tar.gz
cd looking-glass-*/client

echo "==> Configuring"
mkdir -p build && cd build
cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DENABLE_WAYLAND=YES \
      -DENABLE_X11=YES \
      -DENABLE_BACKEND_PIPEWIRE=YES \
      -DCMAKE_BUILD_TYPE=Release \
      ..

echo "==> Building"
make -j"$(nproc)"

echo "==> Installing to $PREFIX"
sudo make install

echo
echo "Client version:"
looking-glass-client --version
echo
echo "Now install the matching host application inside the Windows guest:"
echo "  https://looking-glass.io/downloads   (pick $VERSION)"
echo
echo "Then copy configs/looking-glass/looking-glass-client.ini to"
echo "  ~/.config/looking-glass/client.ini"
echo "and start with: looking-glass-client"
