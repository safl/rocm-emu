#!/bin/bash
# Build the rocjitsu vfio-user server and package it as rocjitsu-host.
#
# Runs inside an ubuntu:$HOST_RELEASE container with the repository at /src and
# writes the .deb and a build directory under /out.
set -euo pipefail
. /src/versions.env

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update
apt-get -qq install -y --no-install-recommends \
	build-essential clang cmake ninja-build git ca-certificates python3 file >/dev/null

src=/out/rocm-systems
if [ ! -d "$src/.git" ]; then
	git init -q "$src"
	git -C "$src" remote add origin "$ROCM_SYSTEMS_REPO"
	git -C "$src" sparse-checkout set emulation/rocjitsu runtimes/api-headers
fi
git -C "$src" fetch -q --depth 1 origin "$ROCM_SYSTEMS_SHA"
git -C "$src" checkout -q FETCH_HEAD

# clang, since libvfio-user's headers use C11 _Static_assert, which g++ rejects
# in the C++ that includes them.
rj=$src/emulation/rocjitsu
CC=clang CXX=clang++ cmake -S "$rj" -B /out/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
	-DROCJITSU_ENABLE_VFIO=ON >/out/configure.log
cmake --build /out/build --target rocjitsu_bin rj_ip_discovery >/out/build.log

version=$(/out/build/tools/rocjitsu/rocjitsu --version | awk 'NR==1 {print $2}')
short=${ROCM_SYSTEMS_SHA:0:7}
stage=/out/stage
rm -rf "$stage"
install -D -m 0755 /out/build/tools/rocjitsu/rocjitsu "$stage/opt/rocjitsu/bin/rocjitsu"
install -D -m 0755 /out/build/tools/rj-ip-discovery/rj-ip-discovery \
	"$stage/opt/rocjitsu/bin/rj-ip-discovery"
install -D -m 0755 /src/host/rocjitsu-vram "$stage/opt/rocjitsu/bin/rocjitsu-vram"
mkdir -p "$stage/opt/rocjitsu/share"
cp -r "$rj/configs" "$stage/opt/rocjitsu/share/configs"
install -D -m 0644 "$rj/LICENSE.md" "$stage/usr/share/doc/rocjitsu-host/copyright"

# rocjitsu links libvfio-user and json-c statically, so the binaries must
# need nothing from the build tree; what they do need comes from the archive.
bins="$stage/opt/rocjitsu/bin/rocjitsu $stage/opt/rocjitsu/bin/rj-ip-discovery"
if ldd $bins | grep -E '=> /out/|not found'; then
	echo "host/build.sh: a binary links something outside the base system" >&2
	exit 1
fi
deps=$(ldd $bins | awk '/=> \// {print $3}' | sort -u | xargs -r realpath |
	xargs -r dpkg -S | cut -d: -f1 | sort -u | paste -sd, | sed 's/,/, /g')
[ -n "$deps" ]

mkdir -p "$stage/DEBIAN"
cat >"$stage/DEBIAN/control" <<EOF
Package: rocjitsu-host
Version: $version+git$short-$PKG_REV
Architecture: amd64
Maintainer: Simon A. F. Lund <os@safl.dk>
Depends: $deps
Section: misc
Priority: optional
Homepage: $ROCM_SYSTEMS_REPO/tree/develop/emulation/rocjitsu
Description: rocjitsu emulated AMD GPU, served over vfio-user
 The rocjitsu vfio-user server from ROCm/rocm-systems $short, built with
 ROCJITSU_ENABLE_VFIO, under /opt/rocjitsu, with its device configs,
 rj-ip-discovery, and rocjitsu-vram, which names the memfd backing a running
 server's VRAM BAR so another vfio-user server can DMA into it.
EOF
dpkg-deb --root-owner-group -Zxz --build "$stage" /out >/dev/null
ls /out/*.deb
