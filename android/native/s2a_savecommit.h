// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_SAVECOMMIT_H
#define S2A_SAVECOMMIT_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Absolute host paths only. No retained state or shared buffers. Callers must
 * serialize mutations of a save tree (including its ancestor directories).
 * Parent path aliases are permitted; final directory symlinks are rejected.
 * This Android implementation selects ordinary read/write copying explicitly;
 * it never probes reflink at runtime. Real I/O errors are returned, not ignored.
 * Clone copies contents, permission bits (not special bits), timestamps and the
 * save token, not ownership, ACLs or arbitrary xattrs. Directories start private
 * (0700), then receive source permissions after their contents are complete.
 * All operations except supported return zero or a positive errno.
 * Symlinks and non-regular/non-directory clone entries are rejected.
 * Clone requires a nonexistent destination; failed clones remove only their
 * newly created tree, and report cleanup errors if it could not be removed. */
int s2a_savecommit_supported(const char *directory);
int s2a_savecommit_clone_tree(const char *source, const char *destination);
int s2a_savecommit_exchange(const char *a, const char *b);
/* At most 64 bytes; .s2a_token and .s2a_token.tmp are reserved metadata names.
 * A committed fallback file takes precedence over user.s2a_token. */
int s2a_savecommit_write_token(const char *directory, const unsigned char *value,
                             size_t length);
/* Missing token succeeds with *length = 0. ERANGE supplies actual length. */
int s2a_savecommit_read_token(const char *directory, unsigned char *buffer,
                            size_t capacity, size_t *length);
/* fsync only this directory; symlink returns nonzero (errno not prescribed). */
int s2a_savecommit_sync_directory(const char *directory);
/* Open an absolute path read-only without following a final symlink or blocking
 * on a FIFO; reject every non-regular file after fstat. On success, *out_fd is
 * owned by the caller, which must close it. On failure, *out_fd is -1 (when
 * out_fd is non-NULL); NULL out_fd returns EINVAL without opening anything.
 * Parent aliases are permitted. Flags come from the target platform headers. */
int s2a_savecommit_open_read(const char *path, int *out_fd);
/* Adapter-only ownership cleanup if wrapping an acquired fd throws. One close
 * attempt, never retry EINTR (Linux may already have released/reused the fd). */
int s2a_savecommit_close_fd(int fd);
#ifdef __cplusplus
}
#endif
#endif
