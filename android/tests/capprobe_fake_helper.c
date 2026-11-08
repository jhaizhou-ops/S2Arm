/* capprobe_fake_helper.c — stand-in for the packaged aarch64 capprobe
 * helper in host tests (capprobe_spawn_test.c). Same contract: invoked
 * as `helper fingerprint` or `helper arm <name>` and writes exactly one
 * contract JSON line on stdout. `arm hang` wedges instead so the parent
 * timeout/kill path can be exercised without a device. The fail/signal/
 * noisy arms plus the CAPPROBE_FAKE_FP_ERROR env knob exist to exercise
 * the runner's stderr capture and wait-status reporting (#1482). */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "fingerprint")) {
        if (getenv("CAPPROBE_FAKE_FP_ERROR")) {
            fputs("fake-helper: vkCreateInstance returned -3\n", stderr);
            fputs("{\"type\":\"fingerprint\",\"error\":\"vkCreateInstance=-3\"}\n",
                  stdout);
            return 2;
        }
        fputs("{\"type\":\"fingerprint\",\"deviceName\":\"FakeGPU\","
              "\"vendorID\":20789,\"deviceID\":1,\"driverVersion\":900,"
              "\"apiVersion\":4198400,\"buildFingerprint\":\"host-test\"}\n",
              stdout);
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "arm")) {
        if (!strcmp(argv[2], "hang")) {
            sleep(60);
            return 0;
        }
        if (!strcmp(argv[2], "sig")) {
            raise(SIGSEGV);
            _exit(1);
        }
        if (!strcmp(argv[2], "fail")) {
            fputs("fake-helper: init failed loudly\n", stderr);
            printf("{\"type\":\"arm\",\"arm\":\"fail\",\"outcome\":\"error\","
                   "\"vk_result\":-3,\"samples\":null,\"elapsed_ms\":1,"
                   "\"stage\":\"init\",\"reason\":\"fake-init\"}\n");
            return 2;
        }
        if (!strcmp(argv[2], "silentfail")) {
            fputs("dying without a contract line\n", stderr);
            return 2;
        }
        if (!strcmp(argv[2], "noisy")) {
            for (int i = 0; i < 64; i++)
                fprintf(stderr,
                        "noise-%02d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
                        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i);
            fputs("stderr-marker-tail\n", stderr);
            printf("{\"type\":\"arm\",\"arm\":\"noisy\",\"outcome\":\"ok\","
                   "\"vk_result\":0,\"samples\":1,\"elapsed_ms\":1,"
                   "\"stage\":\"draw\",\"reason\":\"\"}\n");
            return 0;
        }
        printf("{\"type\":\"arm\",\"arm\":\"%s\",\"outcome\":\"ok\","
               "\"vk_result\":0,\"samples\":1,\"elapsed_ms\":1,"
               "\"stage\":\"draw\",\"reason\":\"\"}\n", argv[2]);
        return 0;
    }
    return 2;
}
