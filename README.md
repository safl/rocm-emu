# rocjitsu packages

Packages for running rocjitsu, ROCm's emulated AMD GPU, as a vfio-user device
beside a QEMU guest, and for qualifying it from inside that guest. The guest
is nosi's `ubuntu-2610-rocm`; nothing here is baked into that image, which is
also flashed onto machines with real GPUs, so the guest packages are installed
at test time into a throwaway guest.

| Package                                  | Where   | What                                                                     |
| ---------------------------------------- | ------- | ------------------------------------------------------------------------ |
| `rocjitsu-host`                          | host    | the rocjitsu vfio-user server, its configs, `rj-ip-discovery`, `rocjitsu-vram` |
| `rocjitsu-guest-firmware`                | guest   | firmware fixtures, the matching `ip_discovery.bin`, the amdgpu options   |
| `rocjitsu-guest-amdgpu-<kernel>`         | guest   | `amdgpu.ko` for exactly that kernel, with the GC 12.1 fixes              |
| `rocjitsu-guest-tests`                   | guest   | `rocjitsu-guest-check gemm` and `rocjitsu-guest-check p2p`               |

`versions.env` holds every pin. The amdgpu package is built from the guest
release's own `linux-source` at the version of the image's kernel, so it moves
whenever the image's kernel does; the firmware package carries the
`ip_discovery.bin` of the server build, so it moves with `rocjitsu-host`.

## Building

```sh
make            # everything, into out/
make guest-amdgpu
```

Each package builds in a container of the Ubuntu release it targets, so
Docker is the only requirement. The rocjitsu configure step fetches
libvfio-user and json-c.

## Using

On the host, start the server, then give QEMU an empty slot to hot-plug it
into later:

```sh
/opt/rocjitsu/bin/rocjitsu --config /opt/rocjitsu/share/configs/gfx1250_mi455x.json \
	--vfio-socket /run/rocjitsu/gpu0.sock
```

In the guest, install the guest packages and load amdgpu before the GPU
appears. udevd reads `modprobe.d` once at start, so a hot-plugged GPU would
otherwise probe without the options:

```sh
apt install ./rocjitsu-guest-firmware_*.deb ./rocjitsu-guest-amdgpu-*.deb ./rocjitsu-guest-tests_*.deb
modprobe amdgpu
```

Then hot-plug the GPU over QMP (HMP's `device_add` cannot express the
socket), and check it from the guest:

```json
{"execute": "device_add", "arguments": {"driver": "vfio-user-pci", "id": "gpu0",
 "bus": "<slot>", "rombar": 0, "socket": {"type": "unix", "path": "/run/rocjitsu/gpu0.sock"}}}
```

```sh
rocjitsu-guest-check gemm
```

## Peer-to-peer

NIC to GPU DMA works on stock QEMU. Two things make it so. The NIC and the
GPU sit on two downstream ports of one emulated PCIe switch
(`x3130-upstream`, `xio3130-downstream`), so the guest kernel's
`pci_p2pdma_distance()` allows it without the q35 host bridge being on its
whitelist. And the NIC's server maps the GPU's VRAM itself: QEMU tells it
where the GPU's BAR is, as a DMA region without a file descriptor, and
`rocjitsu-vram <pid>` names the memfd behind it. For rocm-ernic that is
`--peer-memory "$(rocjitsu-vram <pid>):256M"`, which rocm-ernic does not have
yet.

`rocjitsu-guest-check p2p` registers its VRAM buffer before HIP creates any
queue. Pinning it for the NIC moves it, KFD evicts the process's queues, and
under rocjitsu they do not resume.
