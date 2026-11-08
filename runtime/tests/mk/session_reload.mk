# Explicit CPU-only probe with real rewritten modules. Never part of test/gate:
# input modules are read-only and no game, service host, renderer or save is started.
.PHONY: native-session-probe
native-session-probe: $(VAGUARD)
	@mkdir -p $(BUILD)/session-probe
	$(CC) $(CFLAGS) $(NATIVE_INC) -Dmain=s2a_app_main -c runtime/src/host_main.c -o $(BUILD)/session-probe/host_main.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/probe_session_reload runtime/tests/probe_session_reload.c $(filter-out runtime/src/host_main.c,$(HOST_SRCS)) $(BUILD)/session-probe/host_main.o $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(S2A_HOST_WEAK)

.PHONY: native-session-failure-probe
native-session-failure-probe: $(VAGUARD)
	@mkdir -p $(BUILD)/session-failure-probe
	$(CC) $(CFLAGS) $(NATIVE_INC) -Dmain=s2a_app_main -c runtime/src/host_main.c -o $(BUILD)/session-failure-probe/host_main.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/probe_session_failure runtime/tests/probe_session_failure.c $(filter-out runtime/src/host_main.c,$(HOST_SRCS)) $(BUILD)/session-failure-probe/host_main.o $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(S2A_HOST_WEAK)

.PHONY: native-boot-input-probe
native-boot-input-probe: $(VAGUARD)
	@mkdir -p $(BUILD)/boot-input-probe
	$(CC) $(CFLAGS) $(NATIVE_INC) -Dmain=s2a_app_main -c runtime/src/host_main.c -o $(BUILD)/boot-input-probe/host_main.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/probe_boot_inputs runtime/tests/probe_boot_inputs.c $(filter-out runtime/src/loader.c runtime/src/host_main.c,$(HOST_SRCS)) $(BUILD)/boot-input-probe/host_main.o $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(S2A_HOST_WEAK)
