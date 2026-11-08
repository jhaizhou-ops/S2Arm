// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_lan_elect.h"

#include <string.h>

int s2a_lan_elect(const char *prefix, const char *const *names, int n)
{
    int best = -1;
    if (!prefix || !*prefix || !names || n <= 0)
        return -1;
    const size_t len = strlen(prefix);
    for (int i = 0; i < n; ++i) {
        if (!names[i] || !*names[i] || strncmp(names[i], prefix, len) != 0)
            continue;
        if (best < 0 || strcmp(names[i], names[best]) < 0)
            best = i;
    }
    return best;
}

int s2a_lan_is_self(const char *prefix, const char *dev, const char *name)
{
    if (!prefix || !*prefix || !dev || !*dev || !name || !*name)
        return 0;
    const size_t len = strlen(prefix);
    if (strncmp(name, prefix, len) != 0)
        return 0;
    name += len;
    if (*name == '!')
        ++name;
    return strcmp(name, dev) == 0;
}
