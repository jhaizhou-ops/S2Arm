# Explicit Apple-arm64 CPU probes with local, legally supplied rewritten modules.
# Do not append TEST_TARGETS: neither make test nor gate may require game inputs.
# Build with S2A_CS=0 S2A_MAC_FRONTEND=0; these probes link every production
# HOST_SRCS, rename only host_main's main, and never start services/game/GPU.
ifeq ($(shell uname -s),Darwin)
SDK_STOP_PROBE_UNDEFINED := $(S2A_HOST_WEAK)

.PHONY: native-sdk-stop-probe native-tls-join-block-probe native-fps-reload-probe
.PHONY: native-main-merge-probe
native-main-merge-probe: $(VAGUARD)
	@mkdir -p $(BUILD)/main-merge-probe
	$(CC) $(CFLAGS) $(NATIVE_INC) -Dmain=s2a_app_main -c runtime/src/host_main.c -o $(BUILD)/main-merge-probe/host_main.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/probe_main_merge runtime/tests/probe_main_merge.c $(filter-out runtime/src/host_main.c,$(HOST_SRCS)) $(BUILD)/main-merge-probe/host_main.o $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(SDK_STOP_PROBE_UNDEFINED)

native-fps-reload-probe: $(VAGUARD)
	@mkdir -p $(BUILD)/fps-reload-probe
	$(CC) $(CFLAGS) $(NATIVE_INC) -Dmain=s2a_app_main -c runtime/src/host_main.c -o $(BUILD)/fps-reload-probe/host_main.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/probe_fps_reload runtime/tests/probe_fps_reload.c $(filter-out runtime/src/host_main.c,$(HOST_SRCS)) $(BUILD)/fps-reload-probe/host_main.o $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(SDK_STOP_PROBE_UNDEFINED)

native-sdk-stop-probe: $(VAGUARD)
	@mkdir -p $(BUILD)/sdk-stop-probe
	$(CC) $(CFLAGS) $(NATIVE_INC) -Dmain=s2a_app_main -c runtime/src/host_main.c -o $(BUILD)/sdk-stop-probe/host_main.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -o $(BUILD)/probe_sdk_stop runtime/tests/probe_sdk_stop.c $(filter-out runtime/src/host_main.c,$(HOST_SRCS)) $(BUILD)/sdk-stop-probe/host_main.o $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(SDK_STOP_PROBE_UNDEFINED)

native-tls-join-block-probe: $(VAGUARD)
	@mkdir -p $(BUILD)/tls-join-block-probe
	$(CC) $(CFLAGS) $(NATIVE_INC) -Dmain=s2a_app_main -c runtime/src/host_main.c -o $(BUILD)/tls-join-block-probe/host_main.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -o $(BUILD)/probe_tls_join_block runtime/tests/probe_tls_join_block.c $(filter-out runtime/src/host_main.c,$(HOST_SRCS)) $(BUILD)/tls-join-block-probe/host_main.o $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(SDK_STOP_PROBE_UNDEFINED)
endif
