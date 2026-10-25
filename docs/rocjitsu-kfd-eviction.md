# rocjitsu: user queues never resume after a KFD eviction

A report for rocjitsu, not yet filed.

rocjitsu 98f6a72 (rocm-systems), gfx1250_mi455x.json, served over vfio-user to
QEMU 10.2.1. The guest runs Ubuntu 26.10 (kernel 7.3.0-9-generic) with amdgpu
rebuilt for GC 12.1 and ROCm 10.0 from the archive.

A HIP process that pins one of its own VRAM buffers after its queues exist
hangs on its next GPU operation. The pin comes from registering the buffer as
an RDMA MR (hsa_amd_portable_export_dmabuf() and then ibv_reg_dmabuf_mr(),
which pins through dma_buf_pin() into visible VRAM). The process spins in
user space waiting on a signal. Every kernel ring fence in
amdgpu_fence_info has signaled. /sys/class/kfd/kfd/proc/<pid>/stats_*/
evicted_ms reads 270 and stays there: KFD evicted the process's queues for
the move, but the next dispatch or copy never completes.

The same sequence with the pin made before HIP creates any queue
(hipMalloc, export, register, then hipMemset and hipMemcpy) works, and so
does everything else on the device, a GEMM included. So the suspect is
rocjitsu's handling of the MES remove/add of user queues that eviction and
restore go through.

Reproducer, built with hipcc --offload-arch=gfx1250 -libverbs
-lhsa-runtime64, needing an RDMA device in the guest for the MR:

    hipMalloc(&gpu, 64 KiB); hipMemset(gpu, 0x5a, 64 KiB); hipDeviceSynchronize();
    hsa_amd_portable_export_dmabuf(gpu, 64 KiB, &fd, &off);
    ibv_reg_dmabuf_mr(pd, off, 64 KiB, (uintptr_t)gpu, fd, IBV_ACCESS_LOCAL_WRITE);
    hipMemcpy(host, gpu, 64 KiB, hipMemcpyDeviceToHost);   /* never returns */

Not checked: whether any other eviction (memory pressure, a userptr
invalidation) hangs the same way, and whether a restore that runs after the
queues have gone idle behaves any differently.
