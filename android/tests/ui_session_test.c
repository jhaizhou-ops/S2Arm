// C6：UI broker 绑定真实 session；有在途请求时拒绝换绑，取消后可换。
#include "host_ui_android.h"
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(c, w) do { if (!(c)) { printf("FAIL %s\n", w); failures++; } } while (0)
int main(void) {
    CHECK(s2a_android_ui_bind_session(0) == S2A_HOST_E_ARGUMENT, "zero session rejected");
    CHECK(s2a_android_ui_bind_session(0x1122334455667788ull) == 0, "bind before attach");
    uint64_t generation = s2a_android_ui_attach();
    CHECK(generation != 0, "attach after bind");
    const s2a_host_ui_v1 *ui = s2a_android_ui_table();
    CHECK(ui != NULL, "table ready");
    uint64_t id = 0;
    const char *request = "{\"version\":1,\"type\":\"software-keyboard\",\"mode\":0,\"min\":0,\"max\":16}";
    CHECK(ui && ui->begin(NULL, request, &id) == 0 && id != 0, "request begins");
    CHECK(s2a_android_ui_bind_session(0x8877665544332211ull) == S2A_HOST_E_UNSUPPORTED, "active request blocks rebind");
    CHECK(ui && ui->cancel(NULL, id) == 0, "cancel");
    CHECK(s2a_android_ui_bind_session(0x8877665544332211ull) == 0, "rebind after cancel");
    uint64_t id2 = 0, taken = 0; char text[256]; size_t length = 0;
    CHECK(ui->begin(NULL, request, &id2) == 0 && id2 != 0, "request after rebind");
    CHECK(s2a_android_ui_take(generation, &taken, text, sizeof text, &length) == 0 && taken == id2, "take after rebind");
    CHECK(s2a_android_ui_complete(generation, id2, "{\"version\":1,\"type\":\"software-keyboard\",\"status\":\"cancel\"}") == 0, "complete after rebind");
    s2a_android_ui_detach(generation);
    s2a_android_ui_stop();
    CHECK(s2a_android_ui_bind_session(7) == S2A_HOST_E_UNSUPPORTED, "stopped broker rejects bind");
    if (failures) { printf("ui-session: %d FAILURES\n", failures); return 1; }
    printf("ui-session: ok\n");
    return 0;
}
