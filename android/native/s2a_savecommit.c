// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#define _GNU_SOURCE
#include "s2a_savecommit.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>

#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE 2
#endif
#define TOKEN_ATTR "user.s2a_token"
#define TOKEN_FILE ".s2a_token"
#define TOKEN_TMP ".s2a_token.tmp"
#define DIR_FLAGS (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

static int close_result(int fd, int error)
{
    if (close(fd) < 0 && !error) error = errno;
    return error;
}

static int open_directory(const char *path)
{
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    /* Strip trailing separators so they cannot bypass final-component NOFOLLOW.
     * Parent symlinks are allowed (Android's /data/data alias, for example).
     * Callers own and serialize the save namespace and its ancestors. */
    char *copy = strdup(path);
    if (!copy) return -1;
    size_t n = strlen(copy);
    while (n > 1 && copy[n - 1] == '/') copy[--n] = '\0';
    int fd = open(copy, DIR_FLAGS);
    int error = errno;
    free(copy);
    errno = error;
    return fd;
}

struct parent { int fd; char *storage; char *name; };
static int open_parent(const char *path, struct parent *p)
{
    memset(p, 0, sizeof(*p));
    p->fd = -1;
    if (!path || path[0] != '/') return EINVAL;
    p->storage = strdup(path);
    if (!p->storage) return ENOMEM;
    size_t n = strlen(p->storage);
    while (n > 1 && p->storage[n - 1] == '/') p->storage[--n] = '\0';
    char *slash = strrchr(p->storage, '/');
    p->name = slash + 1;
    if (!*p->name || !strcmp(p->name, ".") || !strcmp(p->name, "..")) {
        free(p->storage); p->storage = NULL; return EINVAL;
    }
    if (slash == p->storage) p->fd = open("/", DIR_FLAGS);
    else {
        *slash = '\0';
        /* Parent aliases are legitimate; final operated entry is checked below. */
        p->fd = open(p->storage, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    }
    if (p->fd < 0) { int e = errno; free(p->storage); p->storage = NULL; return e; }
    return 0;
}
static int close_parent(struct parent *p, int error)
{
    if (p->fd >= 0) error = close_result(p->fd, error);
    free(p->storage);
    return error;
}
static int same_inode(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}
/* Return 1 for ancestor-or-self, 0 otherwise, negative errno on failure. */
static int ancestor(int candidate, int descendant)
{
    struct stat wanted, current, above;
    if (fstat(candidate, &wanted) < 0) return -errno;
    /* Only inspect ancestor identities: listing permission on an unrelated
     * ancestor (e.g. Android /data) is not required to access our own child.
     * O_PATH retains directory/no-follow checks without requesting contents. */
    const int path_flags = O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
    int fd = openat(descendant, ".", path_flags);
    if (fd < 0) return -errno;
    for (;;) {
        if (fstat(fd, &current) < 0) { int e = errno; close(fd); return -e; }
        if (same_inode(&wanted, &current)) { close(fd); return 1; }
        int up = openat(fd, "..", path_flags);
        if (up < 0) { int e = errno; close(fd); return -e; }
        if (fstat(up, &above) < 0) { int e = errno; close(up); close(fd); return -e; }
        close(fd);
        if (same_inode(&current, &above)) { close(up); return 0; }
        fd = up;
    }
}
static int exchange_at(int ap, const char *a, int bp, const char *b)
{
#ifdef SYS_renameat2
    if (syscall(SYS_renameat2, ap, a, bp, b, RENAME_EXCHANGE) < 0) return errno;
    return 0;
#else
    (void)ap; (void)a; (void)bp; (void)b;
    return ENOSYS;
#endif
}
static int write_all(int fd, const unsigned char *data, size_t n)
{
    while (n) {
        ssize_t done = write(fd, data, n);
        if (done < 0) { if (errno == EINTR) continue; return errno; }
        if (!done) return EIO;
        data += done; n -= (size_t)done;
    }
    return 0;
}
static int copy_file(int source, int destination)
{
    /* Android platform policy: ordinary copying, never probe reflink. Reflink
     * is optional, not transaction semantics. Real read/write failures retain
     * their errno; EACCES/EPERM are not treated as capability discovery. */
    int e;
    unsigned char buffer[64 * 1024];
    for (;;) {
        ssize_t n = read(source, buffer, sizeof(buffer));
        if (n < 0) { if (errno == EINTR) continue; return errno; }
        if (!n) return 0;
        e = write_all(destination, buffer, (size_t)n);
        if (e) return e;
    }
}
static int no_xattrs(int e) { return e == ENOTSUP || e == ENOSYS; }

static int write_token_fd(int directory, const unsigned char *value, size_t length)
{
    if (fsetxattr(directory, TOKEN_ATTR, value, length, 0) == 0) {
        /* A file is authoritative while present: remove an old fallback only
         * after the replacement xattr has reached stable storage. */
        if (fsync(directory) < 0) return errno;
        if (unlinkat(directory, TOKEN_FILE, 0) < 0 && errno != ENOENT) return errno;
        return fsync(directory) < 0 ? errno : 0;
    }
    int error = errno;
    if (!no_xattrs(error)) return error;
    int fd = openat(directory, TOKEN_TMP, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0 && errno == EEXIST) {
        /* Callers serialize this reserved name with the save tree. Replace a
         * killed writer's ordinary file, never follow or remove other types.
         * Unlink rather than truncate so another hard link keeps its bytes. */
        struct stat stale;
        if (fstatat(directory, TOKEN_TMP, &stale, AT_SYMLINK_NOFOLLOW) < 0) return errno;
        if (!S_ISREG(stale.st_mode)) return EEXIST;
        if (unlinkat(directory, TOKEN_TMP, 0) < 0) return errno;
        fd = openat(directory, TOKEN_TMP, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    }
    if (fd < 0) return errno;
    error = write_all(fd, value, length);
    if (!error && fsync(fd) < 0) error = errno;
    error = close_result(fd, error);
    if (!error && renameat(directory, TOKEN_TMP, directory, TOKEN_FILE) < 0) error = errno;
    if (error) {
        if (unlinkat(directory, TOKEN_TMP, 0) < 0 && errno != ENOENT) return errno;
        return error;
    }
    return fsync(directory) < 0 ? errno : 0;
}
static int read_token_fd(int directory, unsigned char *buffer, size_t capacity, size_t *length)
{
    int fd = openat(directory, TOKEN_FILE, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) {
        struct stat st;
        int e = 0;
        if (fstat(fd, &st) < 0) e = errno;
        else if (!S_ISREG(st.st_mode) || st.st_size < 0) e = EINVAL;
        else {
            *length = (size_t)st.st_size;
            if (*length > capacity) e = ERANGE;
            else {
                size_t done = 0;
                while (done < *length) {
                    ssize_t n = read(fd, buffer + done, *length - done);
                    if (n < 0) { if (errno == EINTR) continue; e = errno; break; }
                    if (!n) { e = EIO; break; }
                    done += (size_t)n;
                }
            }
        }
        return close_result(fd, e);
    }
    if (errno != ENOENT) return errno;
    ssize_t n = fgetxattr(directory, TOKEN_ATTR, NULL, 0);
    if (n < 0) return (errno == ENODATA || no_xattrs(errno)) ? 0 : errno;
    *length = (size_t)n;
    if (*length > capacity) return ERANGE;
    if (!*length) return 0;
    n = fgetxattr(directory, TOKEN_ATTR, buffer, capacity);
    if (n < 0) {
        int e = errno;
        if (e == ERANGE) {
            n = fgetxattr(directory, TOKEN_ATTR, NULL, 0);
            if (n >= 0) *length = (size_t)n;
        }
        return e;
    }
    *length = (size_t)n;
    return 0;
}
/* Only called for newly created, private directories owned by this operation.
 * Never follows a link, and reports cleanup failure rather than hiding debris. */
static int remove_tree_at(int parent, const char *name)
{
    struct stat owned;
    if (fstatat(parent, name, &owned, AT_SYMLINK_NOFOLLOW) < 0)
        return errno == ENOENT ? 0 : errno;
    if (!S_ISDIR(owned.st_mode)) return ENOTDIR;
    /* Restoring permissions is limited to this invocation's private tree.
     * Namespace serialization is required; no source/preexisting tree comes here. */
    if (fchmodat(parent, name, 0700, 0) < 0) return errno;
    int fd = openat(parent, name, DIR_FLAGS);
    if (fd < 0) return errno;
    int scan = openat(fd, ".", DIR_FLAGS);
    if (scan < 0) return close_result(fd, errno);
    DIR *dir = fdopendir(scan);
    if (!dir) { int e = errno; close(scan); return close_result(fd, e); }
    int error = 0;
    struct dirent *entry;
    for (;;) {
        errno = 0; entry = readdir(dir);
        if (!entry) { if (errno && !error) error = errno; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        struct stat st;
        int e = 0;
        if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0) e = errno;
        else if (S_ISDIR(st.st_mode)) e = remove_tree_at(fd, entry->d_name);
        else if (unlinkat(fd, entry->d_name, 0) < 0) e = errno;
        if (e && !error) error = e;
    }
    if (closedir(dir) < 0 && !error) error = errno;
    error = close_result(fd, error);
    if (unlinkat(parent, name, AT_REMOVEDIR) < 0) return errno;
    return error;
}
static int clone_contents(int source, int destination)
{
    struct stat directory_stat;
    if (fstat(source, &directory_stat) < 0) return errno;
    int scan = openat(source, ".", DIR_FLAGS);
    if (scan < 0) return errno;
    DIR *dir = fdopendir(scan);
    if (!dir) { int e = errno; close(scan); return e; }
    int error = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { error = errno; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        struct stat st;
        if (fstatat(source, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0) { error = errno; break; }
        if (S_ISLNK(st.st_mode)) { error = ELOOP; break; }
        if (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)) { error = EINVAL; break; }
        int in = openat(source, entry->d_name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC |
                        (S_ISDIR(st.st_mode) ? O_DIRECTORY : 0));
        if (in < 0) { error = errno; break; }
        struct stat opened;
        if (fstat(in, &opened) < 0) error = errno;
        else if (!same_inode(&st, &opened)) error = ESTALE;
        int out = -1;
        if (!error && S_ISDIR(st.st_mode)) {
            if (mkdirat(destination, entry->d_name, 0700) < 0) error = errno;
            else {
                out = openat(destination, entry->d_name, DIR_FLAGS);
                if (out < 0) error = errno;
                else error = clone_contents(in, out);
            }
        } else if (!error) {
            out = openat(destination, entry->d_name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (out < 0) error = errno;
            else {
                error = copy_file(in, out);
                if (!error && fchmod(out, st.st_mode & 0777) < 0) error = errno;
                struct timespec times[2] = { st.st_atim, st.st_mtim };
                if (!error && futimens(out, times) < 0) error = errno;
                if (!error && fsync(out) < 0) error = errno;
            }
        }
        if (out >= 0) error = close_result(out, error);
        error = close_result(in, error);
        if (error) break;
    }
    if (closedir(dir) < 0 && !error) error = errno;
    if (!error) {
        unsigned char token[64];
        size_t length = 0;
        error = read_token_fd(source, token, sizeof(token), &length);
        if (!error && length) {
            struct stat fallback;
            /* A fallback token was already copied byte-for-byte with the tree.
             * Do not convert its representation (or change its file metadata). */
            if (fstatat(source, TOKEN_FILE, &fallback, AT_SYMLINK_NOFOLLOW) < 0) {
                if (errno != ENOENT) error = errno;
                else error = write_token_fd(destination, token, length);
            }
        }
    }
    struct timespec times[2] = { directory_stat.st_atim, directory_stat.st_mtim };
    if (!error && fchmod(destination, directory_stat.st_mode & 0777) < 0) error = errno;
    if (!error && futimens(destination, times) < 0) error = errno;
    if (!error && fsync(destination) < 0) error = errno;
    return error;
}

int s2a_savecommit_clone_tree(const char *source, const char *destination)
{
    int in = open_directory(source);
    if (in < 0) return errno;
    struct parent p;
    int error = open_parent(destination, &p);
    if (error) return close_result(in, error);
    struct stat existing;
    /* Existing entries always survive untouched, including symlinks and an
     * existing descendant of source. mkdirat below still closes the race. */
    if (fstatat(p.fd, p.name, &existing, AT_SYMLINK_NOFOLLOW) == 0) error = EEXIST;
    else if (errno != ENOENT) error = errno;
    if (!error) {
        int overlap = ancestor(in, p.fd);
        if (overlap) error = overlap < 0 ? -overlap : EINVAL;
    }
    int owned = 0;
    if (!error) {
        if (mkdirat(p.fd, p.name, 0700) < 0) error = errno;
        else owned = 1;
    }
    if (!error) {
        int out = openat(p.fd, p.name, DIR_FLAGS);
        if (out < 0) error = errno;
        else error = close_result(out, clone_contents(in, out));
    }
    error = close_result(in, error);
    if (error && owned) {
        int cleanup = remove_tree_at(p.fd, p.name);
        if (cleanup) error = cleanup;
    }
    return close_parent(&p, error);
}
int s2a_savecommit_exchange(const char *a, const char *b)
{
    struct parent ap, bp;
    int error = open_parent(a, &ap);
    if (error) return error;
    error = open_parent(b, &bp);
    if (error) return close_parent(&ap, error);
    int af = openat(ap.fd, ap.name, DIR_FLAGS);
    int bf = -1;
    if (af < 0) error = errno;
    else {
        bf = openat(bp.fd, bp.name, DIR_FLAGS);
        if (bf < 0) error = errno;
    }
    if (!error) {
        int ab = ancestor(af, bf), ba = ancestor(bf, af);
        if (ab < 0 || ba < 0) error = ab < 0 ? -ab : -ba;
        else if (ab || ba) error = EINVAL;
        else error = exchange_at(ap.fd, ap.name, bp.fd, bp.name);
    }
    if (af >= 0) error = close_result(af, error);
    if (bf >= 0) error = close_result(bf, error);
    error = close_parent(&bp, error);
    return close_parent(&ap, error);
}
int s2a_savecommit_write_token(const char *directory, const unsigned char *value, size_t length)
{
    if (length > 64 || (length && !value)) return EINVAL;
    int fd = open_directory(directory);
    if (fd < 0) return errno;
    return close_result(fd, write_token_fd(fd, value, length));
}
int s2a_savecommit_read_token(const char *directory, unsigned char *buffer, size_t capacity, size_t *length)
{
    if (!length) return EINVAL;
    *length = 0;
    if (capacity && !buffer) return EINVAL;
    int fd = open_directory(directory);
    if (fd < 0) return errno;
    return close_result(fd, read_token_fd(fd, buffer, capacity, length));
}
int s2a_savecommit_sync_directory(const char *directory)
{
    int fd = open_directory(directory);
    if (fd < 0) return errno;
    int error = fsync(fd) < 0 ? errno : 0;
    return close_result(fd, error);
}
int s2a_savecommit_supported(const char *directory)
{
    int parent = open_directory(directory);
    if (parent < 0) return 0;
    unsigned long long random = 0;
    int rng = open("/dev/urandom", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (rng < 0) { close(parent); return 0; }
    size_t got = 0;
    int error = 0;
    while (got < sizeof(random)) {
        ssize_t n = read(rng, (unsigned char *)&random + got, sizeof(random) - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { error = n < 0 ? errno : EIO; break; }
        got += (size_t)n;
    }
    error = close_result(rng, error);
    char name[80];
    snprintf(name, sizeof(name), ".s2a_probe_%ld_%016llx", (long)getpid(), random);
    int owned = 0;
    if (!error) {
        if (mkdirat(parent, name, 0700) < 0) error = errno;
        else owned = 1;
    }
    if (!error) {
        int probe = openat(parent, name, DIR_FLAGS);
        if (probe < 0) error = errno;
        else {
            if (mkdirat(probe, "a", 0700) < 0 || mkdirat(probe, "b", 0700) < 0) error = errno;
            if (!error) error = exchange_at(probe, "a", probe, "b");
            if (!error && fsync(probe) < 0) error = errno;
            error = close_result(probe, error);
        }
    }
    if (owned) {
        int cleanup = remove_tree_at(parent, name);
        if (cleanup) error = cleanup;
        if (fsync(parent) < 0) error = errno;
    }
    return close_result(parent, error) == 0;
}

int s2a_savecommit_open_read(const char *path, int *out_fd)
{
    if (!out_fd) return EINVAL;
    *out_fd = -1;
    if (!path || path[0] != '/') return EINVAL;
    /* Keep trailing separators intact: a regular-file path ending in '/' must
     * not accidentally become a successful file open. Parent aliases remain
     * permitted; NOFOLLOW protects the final component. NONBLOCK prevents a
     * FIFO from hanging before fstat can reject it. Constants are target-native. */
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return errno;
    struct stat st;
    int error = 0;
    if (fstat(fd, &st) < 0) error = errno;
    else if (!S_ISREG(st.st_mode)) error = EINVAL;
    if (error) return close_result(fd, error);
    *out_fd = fd;
    return 0;
}

int s2a_savecommit_close_fd(int fd)
{
    /* A failed close must not be retried on Linux: fd may already be reused. */
    return close(fd) < 0 ? errno : 0;
}
