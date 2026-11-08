# native-test-envfile：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += envfile
.PHONY: native-test-envfile
native-test-envfile:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_envfile runtime/src/envfile.c runtime/tests/t_envfile.c
	@d=$$(mktemp -d) || exit 1; trap 'rm -f "$$d/Documents/env.txt"; rmdir "$$d/Documents" "$$d"' EXIT; \
	  mkdir "$$d/Documents" && printf 'T_EARLY=from-file\n' > "$$d/Documents/env.txt" || exit 1; \
	  for mode in docs home explicit missing; do \
	    case $$mode in \
	      docs) env -u T_EARLY S2A_DOCS="$$d/Documents" T_EXPECT_EARLY=from-file $(BUILD)/tests/t_envfile $$mode;; \
	      home) env -u T_EARLY -u S2A_DOCS HOME="$$d" T_EXPECT_EARLY=from-file $(BUILD)/tests/t_envfile $$mode;; \
	      explicit) T_EARLY=explicit S2A_DOCS="$$d/Documents" T_EXPECT_EARLY=explicit $(BUILD)/tests/t_envfile $$mode;; \
	      missing) env -u T_EARLY S2A_DOCS="$$d/missing" T_EXPECT_EARLY= $(BUILD)/tests/t_envfile $$mode;; \
	    esac 2> $(BUILD)/tests/envfile-$$mode.log; rc=$$?; \
	    cat $(BUILD)/tests/envfile-$$mode.log; \
	    [ $$rc = 0 ] && [ "$$(head -1 $(BUILD)/tests/envfile-$$mode.log)" = T_ENVFILE_MAIN ] || exit 1; \
	  done
TEST_TARGETS += native-test-envfile
