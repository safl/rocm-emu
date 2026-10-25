# Build every package in a container of the release it targets, into out/.
include versions.env

DOCKER ?= docker
OUT ?= $(CURDIR)/out
RUN = $(DOCKER) run --rm -v $(CURDIR):/src:ro

.PHONY: all host guest-firmware guest-amdgpu guest-tests verify clean

all: host guest-firmware guest-amdgpu guest-tests

host: $(OUT)/host/.built

$(OUT)/host/.built: versions.env host/build.sh host/rocjitsu-vram
	mkdir -p $(OUT)/host
	$(RUN) -v $(OUT)/host:/out ubuntu:$(HOST_RELEASE) bash /src/host/build.sh
	touch $@

# ip_discovery.bin comes from the host package's rj-ip-discovery.
guest-firmware: $(OUT)/host/.built
	mkdir -p $(OUT)/guest-firmware
	$(RUN) -v $(OUT):/out ubuntu:$(HOST_RELEASE) bash /src/guest/firmware/build.sh \
		$$(cd $(OUT) && ls host/rocjitsu-host_*.deb | sed 's|^|/out/|') /out/guest-firmware

guest-amdgpu:
	mkdir -p $(OUT)/guest-amdgpu
	$(RUN) -v $(OUT)/guest-amdgpu:/out ubuntu:$(GUEST_RELEASE) bash /src/guest/amdgpu/build.sh

guest-tests:
	mkdir -p $(OUT)/guest-tests
	$(RUN) -v $(OUT)/guest-tests:/out ubuntu:$(HOST_RELEASE) bash /src/guest/tests/build.sh /out

# Run the cijoe workflow against the packages in /tmp/artifacts, with
# rocjitsu-host installed; this is what CI runs.
CIJOE_OUTPUT ?= cijoe-output
verify:
	cd cijoe && cijoe workflows/test-ubuntu-2610-rocm-gpu.yaml --monitor \
		--config configs/ubuntu-2610-rocm-gpu.toml \
		--config configs/system_imaging.toml \
		--output $(CIJOE_OUTPUT)

clean:
	rm -rf $(OUT)
