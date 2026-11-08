// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_LAN_ELECT_H
#define S2A_LAN_ELECT_H

#ifdef __cplusplus
extern "C" {
#endif

/* Select the bytewise-smallest name beginning with prefix ("<program>-").
 * The caller must include the local advertised name in names. Return its
 * original array index, or -1 if no candidate exists. Equal names select the
 * first index. NULL/empty entries are ignored. NULL/empty prefix, NULL names,
 * or n <= 0 returns -1. Names and prefix are NUL-terminated byte strings; callers
 * supply valid published names (prefix + optional "!" + alphanumeric device).
 * For n > 0, names points to at least n entries. All borrowed storage must
 * remain valid and unchanged during the call. Published-name grammar and
 * string lengths are not validated: this function only compares them.
 * No allocation, locks, I/O, or retained/global state.
 */
int s2a_lan_elect(const char *prefix, const char *const *names, int n);

/* Match exactly prefix + dev or prefix + "!" + dev. A device identifier is
 * stable and alphanumeric; callers supply valid prefix/device identifiers.
 * NULL or empty arguments return 0. Pure and thread-safe like elect above.
 */
int s2a_lan_is_self(const char *prefix, const char *dev, const char *name);

#ifdef __cplusplus
}
#endif

#endif
