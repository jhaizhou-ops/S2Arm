// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include <stdio.h>
extern int s2a_savecommit_managed_test(const unsigned char *path, int *checks);
int suite_main(int argc, char **argv)
{
    if (argc != 2) return 2;
    int checks = 0;
    int result = s2a_savecommit_managed_test((const unsigned char *)argv[1], &checks);
    if (result == 0 && checks != 21) {
        fprintf(stderr, "managed probe returned incomplete check count: %d/21\n", checks);
        result = 1;
    }
    printf("savecommit managed: %d checks, %d failures\n", checks, result != 0);
    return result;
}
