# Explicit CPU probe with existing real modules; no automatic game/gate input.
# This source path also lets a frozen baseline compile the identical oracle.
BOOT_ABORT_PROBE_SRC := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../probe_boot_abort.c)
.PHONY: native-boot-abort-probe
native-boot-abort-probe: $(VAGUARD)
	@mkdir -p $(BUILD)/boot-abort-probe
	$(CC) $(CFLAGS) $(NATIVE_INC) -Dmain=s2a_app_main -c runtime/src/host_main.c -o $(BUILD)/boot-abort-probe/host_main.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/probe_boot_abort $(BOOT_ABORT_PROBE_SRC) $(filter-out runtime/src/host_main.c,$(HOST_SRCS)) $(BUILD)/boot-abort-probe/host_main.o $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(S2A_HOST_WEAK)
