#!/bin/bash
# Package the guest checks as rocjitsu-guest-tests: sources and a runner, since
# the guest has hipcc and compiling there keeps the package independent of the
# ROCm the image carries.
#
#   build.sh <output dir>
set -euo pipefail
. /src/versions.env
out=$1

stage=$out/stage
rm -rf "$stage"
install -D -m 0755 /src/guest/tests/rocjitsu-guest-check "$stage/usr/bin/rocjitsu-guest-check"
for t in sgemm rdma_p2p; do
	install -D -m 0644 "/src/guest/tests/$t.hip" "$stage/usr/share/rocjitsu-guest-tests/$t.hip"
done

mkdir -p "$stage/DEBIAN"
cat >"$stage/DEBIAN/control" <<EOF
Package: rocjitsu-guest-tests
Version: 0.1.0-$PKG_REV
Architecture: all
Maintainer: Simon A. F. Lund <os@safl.dk>
Depends: hipcc-rocm, libhsa-runtime-dev, libibverbs-dev
Section: devel
Priority: optional
Description: checks for a rocjitsu GPU inside a guest
 rocjitsu-guest-check runs a GEMM on the GPU, checked element by element on
 the CPU, and an RDMA test that writes into, reads out of and sends into VRAM
 exported as a dma-buf, every byte read back through HIP.
EOF
dpkg-deb --root-owner-group -Zxz --build "$stage" "$out" >/dev/null
ls "$out"/*.deb
