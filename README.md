# rocm-emu

An emulated AMD GPU and an emulated RDMA NIC in one QEMU guest, the NIC doing
DMA into the GPU's VRAM, on stock QEMU and a stock GitHub runner. The GPU is
rocjitsu, ROCm's GPU emulator, served over vfio-user; the NIC is
[rocm-ernic](https://github.com/ROCm/rocm-ernic); the guest is nosi's
`ubuntu-2610-rocm`. This is where it gets proven before it goes into xNVMe's
CI, beside the rocm-ernic job there, for testing device paths into GPU memory
without a GPU.

What it took, and what is still wrong, is in [docs/findings.md](docs/findings.md).

## What is here

| Path                     | What                                                                    |
| ------------------------ | ----------------------------------------------------------------------- |
| `host/`, `guest/`        | the packages, below                                                     |
| `patches/rocm-ernic/`    | `--peer-memory`, the rocm-ernic change NIC to GPU DMA needs; carried until upstream |
| `cijoe/`                 | the check, as cijoe configs, scripts and a workflow laid out as xNVMe's |
| `.github/workflows/`     | builds the packages, then runs the check                                |
| `docs/`                  | findings, and a rocjitsu bug report not yet filed                       |

The cijoe pieces are xNVMe's: `rocm_ernic_build.py` and `root_unlock.py` are
from xNVMe's `cijoe/scripts` (the former extended to apply patches), and
`rocjitsu_guest_start.py` follows its `xnvme_guest_start_nvme.py`.

## Packages

| Package                                  | Where   | What                                                                     |
| ---------------------------------------- | ------- | ------------------------------------------------------------------------ |
| `rocjitsu-host`                          | host    | the rocjitsu vfio-user server, its configs, `rj-ip-discovery`, `rocjitsu-vram` |
| `rocjitsu-guest-firmware`                | guest   | firmware fixtures, the matching `ip_discovery.bin`, the amdgpu options   |
| `rocjitsu-guest-amdgpu-<kernel>`         | guest   | `amdgpu.ko` for exactly that kernel, with the GC 12.1 fixes              |
| `rocjitsu-guest-tests`                   | guest   | `rocjitsu-guest-check gemm` and `rocjitsu-guest-check p2p`               |

Nothing is baked into the nosi image, which is also flashed onto machines with
real GPUs; the guest packages are installed at test time into a throwaway
guest. `versions.env` holds every pin. The amdgpu package is built from the
guest release's own `linux-source` at the version of the image's kernel, so it
moves whenever the image's kernel does; the firmware package carries the
`ip_discovery.bin` of the server build, so it moves with `rocjitsu-host`.

## Running it

```sh
make                      # the packages, into out/, each in a container of its release
```

The check wants a Linux host with KVM, QEMU 10.1 or later, oras and pipx, as
in nosi's `ubuntu-2604-docker` image, which CI runs it in:

```sh
sudo apt install ./out/host/rocjitsu-host_*.deb
mkdir -p /tmp/artifacts && cp out/guest-*/*.deb /tmp/artifacts
pipx install ./cijoe --include-deps
make verify
```

It starts both servers and the guest, installs the guest packages, loads
amdgpu and hot-plugs the GPU, then runs the GEMM and the P2P check, and fails
unless the NIC's server logs serving DMA from the GPU's VRAM.

To do it by hand: the GPU must be hot-plugged after `modprobe amdgpu`, over
QMP, onto a downstream port of the same PCIe switch as the NIC, and the NIC's
server needs `--peer-memory "$(rocjitsu-vram <rocjitsu pid>):256M"`.
`cijoe/scripts/rocjitsu_guest_start.py` has the QEMU arguments.

## Licensing

BSD-3-Clause (`LICENSE`), except where a file says otherwise:
`guest/firmware/vfio_guest_firmware.py` is AMD's, MIT, vendored from
ROCm/rocm-systems `730bc62`; `guest/tests/rdma_p2p.hip` is GPL-2.0-or-later,
following rocm-ernic's tests; the patches are under the licenses of what they
patch.
