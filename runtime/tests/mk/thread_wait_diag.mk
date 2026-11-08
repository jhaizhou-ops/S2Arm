NATIVE_TEST_OWN += thread_wait_diag
.PHONY: native-test-thread_wait_diag
native-test-thread_wait_diag:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_thread_wait_diag runtime/tests/t_thread_wait_diag.c runtime/src/thread.c
	$(BUILD)/tests/t_thread_wait_diag off > $(BUILD)/tests/wait-diag-off.log 2>&1
	$(BUILD)/tests/t_thread_wait_diag on > $(BUILD)/tests/wait-diag-on.log 2>&1
	python3 runtime/tests/support/check_wait_diag.py $(BUILD)/tests/wait-diag-off.log $(BUILD)/tests/wait-diag-on.log
	@# 安卓暂停 / 条件等待协议夹具（Darwin 适配层编真实安卓函数体，#1309）：测的是 S2A_ANDROID_WAIT_PAUSE 候选实现（目标自己停进 park），
	@#   缺省模式是暂停方代发 ack、不走这条，故带 --enable-wait-pause；输出须在仓库外，跑完删
	d=$$(mktemp -d "$${TMPDIR:-/tmp}/s2a_pwh.XXXXXX") && case "$$d" in */s2a_pwh.*) ;; *) exit 1;; esac && \
	  { python3 runtime/tests/support/run_pause_wait_host.py --out "$$d" --enable-wait-pause; rc=$$?; [ $$rc = 0 ] || cat "$$d"/*.log | grep -a FAIL | head -20; rm -rf "$$d"; exit $$rc; }
	@# 同一夹具的总入口：缺省模式（暂停方代发 ack）+ 候选协议 + ASan + 5 种变异反证（删返回屏障 / 叫醒 / pins 等必须抓红），约 40 秒
	d=$$(mktemp -d "$${TMPDIR:-/tmp}/s2a_pwc.XXXXXX") && case "$$d" in */s2a_pwc.*) ;; *) exit 1;; esac && \
	  { python3 runtime/tests/support/run_pause_wait_checks.py --out "$$d" > "$$d.log" 2>&1; rc=$$?; [ $$rc = 0 ] || tail -20 "$$d.log"; rm -rf "$$d" "$$d.log"; exit $$rc; }
	@echo "✓ t_thread_wait_diag"
TEST_TARGETS += native-test-thread_wait_diag
