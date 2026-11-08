// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef OWNED_DIRECTORY_H
#define OWNED_DIRECTORY_H
#include <sys/stat.h>
#include <sys/types.h>
// Both successful calls must identify the same caller-owned directory.
// Original metadata is from lstat: a final symlink is never accepted.
static int owned_directory_identity(const struct stat *original,const struct stat *canonical,uid_t owner) {
 return S_ISDIR(original->st_mode) && S_ISDIR(canonical->st_mode)
  && original->st_uid==owner && canonical->st_uid==owner
  && original->st_dev==canonical->st_dev && original->st_ino==canonical->st_ino;
}
#endif
