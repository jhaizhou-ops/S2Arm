# native-test-restart_done：重启完成登记点（runtime/src/session.c s2a_session_on_restart_done；iOS 壳靠它放重启首帧屏障，设置页 / 游戏发起同一处）
NATIVE_TEST_OWN += restart_done
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-restart_done
native-test-restart_done:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_restart_done runtime/tests/t_restart_done.c runtime/src/session.c
	$(BUILD)/tests/t_restart_done
TEST_TARGETS += native-test-restart_done
endif
