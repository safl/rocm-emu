#!/bin/bash
# Package the guest's firmware and amdgpu options as rocjitsu-guest-firmware.
#
# Runs after host/build.sh in the same kind of container: ip_discovery.bin
# comes from that build's rj-ip-discovery, so it matches the server.
#
#   build.sh <rocjitsu-host .deb> <output dir>
set -euo pipefail
. /src/versions.env
host_deb=$1
out=$2

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update
apt-get -qq install -y --no-install-recommends python3 >/dev/null

version=$(dpkg-deb -f "$host_deb" Version)
host=$out/host
rm -rf "$host"
dpkg-deb -x "$host_deb" "$host"
stage=$out/stage
fw=$stage/lib/firmware/updates/amdgpu
rm -rf "$stage"
mkdir -p "$(dirname "$fw")"

python3 -I /src/guest/firmware/vfio_guest_firmware.py --output "$fw"
"$host/opt/rocjitsu/bin/rj-ip-discovery" gfx1250 "$fw/ip_discovery.bin"

# The fixture's MEC reports ucode_version 1. KFD then wants PCIe atomics from
# the root port, which QEMU never offers a vfio-user device; 2090 is the gfx12
# MEC release KFD accepts without them. ucode_version is outside the CRC.
python3 -I - "$fw/gc_12_1_0_mec.bin" <<'EOF'
import struct, sys
with open(sys.argv[1], "r+b") as f:
    f.seek(16)
    f.write(struct.pack("<I", 2090))
EOF

install -D -m 0644 /src/guest/firmware/amdgpu-rocjitsu.conf \
	"$stage/etc/modprobe.d/amdgpu-rocjitsu.conf"
install -D -m 0644 /src/guest/firmware/LICENSE.vfio_guest_firmware.md \
	"$stage/usr/share/doc/rocjitsu-guest-firmware/copyright"

mkdir -p "$stage/DEBIAN"
cat >"$stage/DEBIAN/control" <<EOF
Package: rocjitsu-guest-firmware
Version: $version
Architecture: all
Maintainer: Simon A. F. Lund <os@safl.dk>
Section: kernel
Priority: optional
Description: firmware and amdgpu options for a guest with a rocjitsu GPU
 Firmware-format fixtures from rocjitsu (headers and sentinel payloads, not
 AMD firmware) and the ip_discovery.bin of the matching rocjitsu-host, under
 /lib/firmware/updates/amdgpu, plus the amdgpu emulation options.
 .
 Install it only in a guest whose GPU is rocjitsu: the options it sets break
 a real AMD GPU. udevd reads modprobe.d when it starts, so load amdgpu by hand
 after installing and before the GPU appears.
EOF
dpkg-deb --root-owner-group -Zxz --build "$stage" "$out" >/dev/null
ls "$out"/*.deb
