#!/usr/bin/env python3
"""
Attach the emulated GPU to a running guest
==========================================

Installs the guest packages, loads amdgpu, and only then hot-plugs the
rocjitsu GPU over the guest's QMP socket, onto the port rocjitsu_guest_start
left free; it returns once the guest has a KFD and a render node.

amdgpu goes first because udevd reads modprobe.d once, when it starts: a GPU
probed by udev would come up without the options the packages install. QMP
rather than HMP, since HMP's device_add cannot express the vfio-user socket.

The packages are the .deb files in 'rocjitsu.guest_debs'.

Retargetable: false
-------------------
"""
import errno
import json
import logging as log
import socket
import time
from argparse import ArgumentParser
from pathlib import Path

import rocjitsu_guest_start

from cijoe.qemu.wrapper import Guest


def add_args(parser: ArgumentParser):
    parser.add_argument("--guest_name", type=str, default=None)
    parser.add_argument(
        "--timeout",
        type=int,
        default=180,
        help="Seconds to wait for the guest's KFD and render node.",
    )


def qmp(path, command, arguments):
    """Run one QMP command on the socket at 'path'; return its reply"""

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(str(path))
        stream = sock.makefile("rw")
        stream.readline()  # the greeting
        for msg in (
            {"execute": "qmp_capabilities"},
            {"execute": command, "arguments": arguments},
        ):
            stream.write(json.dumps(msg) + "\n")
            stream.flush()
            while True:
                reply = json.loads(stream.readline())
                if "event" not in reply:
                    break
        return reply


def main(args, cijoe):
    """Install the guest packages, load amdgpu, then hot-plug the GPU"""

    guest_name = args.guest_name or cijoe.getconf("qemu.default_guest")
    guest = Guest(cijoe, cijoe.config, guest_name)

    debs = sorted(Path(cijoe.getconf("rocjitsu.guest_debs")).glob("rocjitsu-guest-*.deb"))
    if not debs:
        log.error(f"no rocjitsu-guest-*.deb in {cijoe.getconf('rocjitsu.guest_debs')}")
        return errno.ENOENT

    for deb in debs:
        if not cijoe.put(str(deb), f"/tmp/{deb.name}"):
            return errno.EIO

    err, _ = cijoe.run(
        "DEBIAN_FRONTEND=noninteractive apt-get -qy update && "
        "DEBIAN_FRONTEND=noninteractive apt-get -qy install "
        + " ".join(f"/tmp/{deb.name}" for deb in debs)
        + " && modprobe amdgpu"
    )
    if err:
        return err

    reply = qmp(
        guest.guest_path / "qmp.sock",
        "device_add",
        {
            "driver": "vfio-user-pci",
            "id": "gpu0",
            "bus": rocjitsu_guest_start.GPU_PORT,
            "rombar": 0,
            "socket": {"type": "unix", "path": cijoe.getconf("rocjitsu.socket")},
        },
    )
    if "return" not in reply:
        log.error(f"device_add: {reply}")
        return errno.EIO

    began = time.time()
    while time.time() - began < args.timeout:
        err, _ = cijoe.run("test -e /dev/kfd && ls /dev/dri | grep -q renderD")
        if not err:
            return 0
        time.sleep(5)

    log.error("the guest has no KFD and render node; see its dmesg")
    cijoe.run("dmesg | grep -i amdgpu | tail -40")
    return errno.ETIMEDOUT
