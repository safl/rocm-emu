# Findings

What it took to run rocjitsu, ROCm's emulated AMD GPU, as a vfio-user device
in a QEMU guest beside rocm-ernic, ROCm's emulated RDMA NIC, with the NIC
doing DMA into the GPU's VRAM. Everything ran on stock QEMU 10.2.1 with KVM,
the guest being nosi's `ubuntu-2610-rocm:2026.W43` (Ubuntu 26.10, kernel
7.3.0-9-generic, ROCm 10.0 from the archive), rocjitsu from ROCm/rocm-systems
`98f6a72`, rocm-ernic `cddb171`.

## The guest kernel

The stock 7.3 amdgpu does not bring up GC 12.1 under rocjitsu. Three gaps,
all still on mainline master at the drm-next merge of 2026-10-21:

1. `gmc_v12_0.c` and `soc_v1_0.c` put the GC 12.1 memory-range init and
   `get_xcp_mem_id` behind `#ifdef HAVE_ACPI_DEV_GET_FIRST_MATCH_DEV`, a DKMS
   compat macro the in-tree build never defines. Without it
   `num_mem_partitions` is 0, and gfx_v12_1 hw_init fails with "no compatible
   compute partition mode found". This likely affects a real MI455X as well.
   The package builds with `-DHAVE_ACPI_DEV_GET_FIRST_MATCH_DEV`.
2. `soc_v1_0_common_early_init()` never calls
   `adev->nbio.funcs->set_reg_remap()`, unlike nv, soc15, soc21 and soc24,
   so `rmmio_remap.bus_addr` is 0 and KFD refuses ROCr's MMIO remap page
   (`AMDKFD_IOC_ALLOC_MEMORY_OF_GPU` returns -ENOMEM). Patch 0001.
3. rocjitsu's `ip_discovery.bin` carries GC info v2.0, which has no cache
   sizes, so KFD reports no caches, and Ubuntu's ROCr, built with asserts,
   aborts on "GPU cache info missing". Patch 0002 falls back to
   `dummy_cache_info`. The right fix is rocjitsu emitting GC info v2.1.

Gaps 1 and 2 belong upstream on amd-gfx, gap 3 in rocjitsu. Until then the
`rocjitsu-guest-amdgpu-<kernel>` package carries an `amdgpu.ko` rebuilt from
that kernel's own `linux-source`, installed under `updates/`.

## Firmware and options

No AMD firmware is needed. rocjitsu's `vfio_guest_firmware.py --set full`
emits stubs for the whole set, and `ip_discovery.bin` comes from the server
build's `rj_ip_discovery`, so it moves with the server.

KFD's atomics gate: QEMU adds AtomicOps completer support to a root port only
for a kernel-VFIO device, never for vfio-user, and the stub MEC reports
ucode_version 1. Stamping 2090 into the stub MEC header, the gfx12 release
KFD accepts without atomics, gets past it with no driver change.

`ip_block_mask=0x3f` is right for mainline with `discovery=2`: common, gmc,
ih, gfx, sdma, mes. The full option line is in
`guest/firmware/amdgpu-rocjitsu.conf`.

## Nothing baked into the image

nosi's `ubuntu-2610-rocm` is also flashed onto machines with real GPUs, where
the emulation options would break them, so none of this is in the image. The
guest boots with an empty PCIe port, installs the packages, runs
`modprobe amdgpu`, and only then is the GPU hot-plugged over QMP. The order
matters: udevd reads `modprobe.d` once at start, and `udevadm control
--reload` does not refresh it, so a GPU probed by udev would come up without
the options. HMP's `device_add` cannot express the vfio-user socket; QMP can.

## User space

The archive's rocBLAS has no gfx1250 code objects (gfx908 to gfx1201 only),
so rocjitsu's own rocBLAS qualification cannot run. HIP and ROCr do support
gfx1250, so a HIP kernel does: `rocjitsu-guest-check gemm` is a hand-written
FP32 GEMM checked element by element on the CPU.

Ubuntu's ROCr insists on `libhsa_hotswap_rocjitsu.so` for a gfx1250 A0 agent
(ASIC revision 0) and fails `hsa_init` with OUT_OF_RESOURCES without it.
Nothing ships it. `HSA_HOTSWAP_DISABLE=1` skips it, and results are correct
without it.

In 26.10, hipcc is the package `hipcc-rocm`, and `hsa_ext_amd.h` is in
`libhsa-runtime-dev`.

## NIC to GPU DMA on stock QEMU

This was thought to need a QEMU patch ("hw/vfio: assign region fd to RAMBlock
for vfio-user P2P DMA", `31e3d06a` on sbates130272/qemu). It does not. Two
things make it work.

The topology. The NIC and the GPU sit on two downstream ports of one emulated
PCIe switch (`x3130-upstream`, two `xio3130-downstream`). The guest kernel's
`pci_p2pdma_distance()` allows P2P between devices behind one switch; between
root ports it would need the q35 host bridge on its whitelist. Without it,
amdgpu quietly places a P2P buffer in system memory and every test passes
without touching VRAM.

The NIC server maps VRAM itself. QEMU announces another vfio-user device's
mmap-able BAR to a vfio-user server as a DMA region, but without a file
descriptor: `vfio_user_dma_map()` sends one only when `memory_region_get_fd()`
returns one. libvfio-user's `vfu_sgl_get()` then fails with EFAULT. rocjitsu
backs BAR0 with a memfd (`rocjitsu-vram`, BAR0 at offset 0, 256M), so
rocm-ernic's new `--peer-memory FILE:SIZE`, given `/proc/<rocjitsu pid>/fd/N`,
maps it for the first fd-less region of that size, and the datapath falls back
to it on EFAULT. That change is `patches/rocm-ernic/`, to go upstream.

Ruled out: falling back to `vfu_sgl_read()` and `vfu_sgl_write()`, which QEMU
does serve as messages. On the single socket the replies collide with the
client's own requests ("bad reply to DMA transfer"); libvfio-user warns that
twin_socket is not enabled, and QEMU has no twin socket.

The guest side: the ionic DKMS driver in the image implements
`reg_user_mr_dmabuf` via `ib_umem_dmabuf_get_pinned`, the kernel has
`CONFIG_PCI_P2PDMA=y`, and amdgpu pins P2P buffers in visible VRAM.
`rocjitsu-guest-check p2p` exports `hipMalloc` memory with
`hsa_amd_portable_export_dmabuf()`, registers it with `ibv_reg_dmabuf_mr()`,
and checks RDMA WRITE into VRAM, READ out of it and SEND into a receive posted
on it, every byte read back through HIP. The server log names the address the
NIC was handed, inside the GPU's BAR0.

## Known rocjitsu bug

Pinning a buffer for an MR after HIP has created its queues hangs the
process; see [rocjitsu-kfd-eviction.md](rocjitsu-kfd-eviction.md). The p2p
check registers its MR before HIP creates any queue.

## Not exercised

Hot-unplug (it killed QEMU once and was not pursued), TCG, more than one GPU,
NVMe or xNVMe moving data into VRAM, and any kernel other than
7.3.0-9-generic.
