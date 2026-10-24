#!/bin/bash
# Build amdgpu.ko for the guest kernel, with what GC 12.1 under rocjitsu needs,
# and package it as rocjitsu-guest-amdgpu-$GUEST_KVER.
#
# Runs inside an ubuntu:$GUEST_RELEASE container with the repository at /src,
# writing to /out. The source is that release's own linux-source at exactly the
# version of the guest's kernel, so the module matches the kernel it loads into.
set -euo pipefail
. /src/versions.env

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update
apt-get -qq install -y --no-install-recommends \
	"$GUEST_KSRC=$GUEST_KSRC_VERSION" "linux-headers-$GUEST_KVER=$GUEST_KSRC_VERSION" \
	build-essential bzip2 patch >/dev/null

tree=/out/tree
rm -rf "$tree"
mkdir -p "$tree"
tar -xjf "/usr/src/$GUEST_KSRC.tar.bz2" -C "$tree" --strip-components=1 \
	"$GUEST_KSRC/drivers/gpu/drm/amd"
for p in /src/guest/amdgpu/patches/*.patch; do
	patch -s -p1 -d "$tree" <"$p"
done

# HAVE_ACPI_DEV_GET_FIRST_MATCH_DEV is a DKMS compat macro that the in-tree
# build never defines, yet gmc_v12_0.c and soc_v1_0.c put the GC 12.1 memory
# partition setup behind it; without it gfx_v12_1 hw_init fails with -EINVAL.
# The trace headers name themselves relative to include/trace, so that has to
# sit beside drivers/ for them to be found in this tree, not the headers'.
mkdir -p "$tree/include/trace"
make -s -j"$(nproc)" -C "/usr/src/linux-headers-$GUEST_KVER" \
	M="$tree/drivers/gpu/drm/amd/amdgpu" \
	KCFLAGS="-DHAVE_ACPI_DEV_GET_FIRST_MATCH_DEV -I$tree/include/trace" \
	modules >/out/build.log 2>&1 || { tail -40 /out/build.log; exit 1; }

pkg=rocjitsu-guest-amdgpu-$GUEST_KVER
stage=/out/stage
rm -rf "$stage"
mkdir -p "$stage/lib/modules/$GUEST_KVER/updates" "$stage/DEBIAN"
strip --strip-debug -o "$stage/lib/modules/$GUEST_KVER/updates/amdgpu.ko" \
	"$tree/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
mkdir -p "$stage/usr/share/doc/$pkg/patches"
cp /src/guest/amdgpu/patches/*.patch "$stage/usr/share/doc/$pkg/patches/"

cat >"$stage/DEBIAN/control" <<EOF
Package: $pkg
Version: $GUEST_KSRC_VERSION+rj$PKG_REV
Architecture: amd64
Maintainer: Simon A. F. Lund <os@safl.dk>
Depends: linux-modules-$GUEST_KVER (= $GUEST_KSRC_VERSION)
Section: kernel
Priority: optional
Description: amdgpu for a guest with a rocjitsu GPU, kernel $GUEST_KVER
 amdgpu.ko from $GUEST_KSRC $GUEST_KSRC_VERSION, installed under updates/ so
 it takes precedence over the kernel's own, with the changes GC 12.1 needs
 that mainline lacks: the memory partition setup that sits behind a DKMS-only
 macro, the register remap SOC v1.0 never sets up, and a cache info fallback
 for an IP discovery table without cache sizes. The patches are in
 /usr/share/doc/$pkg/patches.
EOF
for script in postinst postrm; do
	printf '#!/bin/sh\nset -e\ndepmod -a %s\n' "$GUEST_KVER" >"$stage/DEBIAN/$script"
	chmod 0755 "$stage/DEBIAN/$script"
done
dpkg-deb --root-owner-group -Zxz --build "$stage" /out >/dev/null
ls /out/*.deb
