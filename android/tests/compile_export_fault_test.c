#include "direct/compile_export.h"
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    const unsigned char identity[32] = {7};
    const char *body = "complete request bytes";
    return s2a_compile_export_request(argv[1], 1, 2, 3, 1, "closure", "profile", "request", identity, body, strlen(body)) == 0 ? 0 : 1;
}
