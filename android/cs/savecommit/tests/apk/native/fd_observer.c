// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
// Only calls linked from this test DSO are wrapped. No system-wide hook.
DIR *__real_opendir(const char *);
struct dirent *__real_readdir(DIR *);
int __real_closedir(DIR *);
static _Thread_local DIR *observed;
static _Thread_local unsigned scan;
static _Thread_local unsigned entries_seen;
static void emit(const char *line) {
 // stderr already opened by harness; no open/dup/new fd. Preserve errno in callers.
 fputs(line,stderr);fflush(stderr);
}
DIR *__wrap_opendir(const char *path) {
 DIR *d=__real_opendir(path);int saved=errno;
 if(d && !strcmp(path,"/proc/self/fd") && !observed) {
  observed=d;entries_seen=0;++scan;
  char line[256];snprintf(line,sizeof line,"FD_SCAN_BEGIN thread=%lu scan=%u scan_fd=%d\n",(unsigned long)pthread_self(),scan,dirfd(d));emit(line);
 }
 errno=saved;return d;
}
struct dirent *__wrap_readdir(DIR *d) {
 struct dirent *e=__real_readdir(d);int saved=errno;
 if(d==observed && e && strcmp(e->d_name,".") && strcmp(e->d_name,"..")) {
  ++entries_seen;
  char target[4096],escaped[8192],line[8704];
  errno=0;ssize_t n=readlinkat(dirfd(d),e->d_name,target,sizeof target-1);int link_errno=errno;
  size_t o=0;
  if(n>=0)for(ssize_t i=0;i<n && o+4<sizeof escaped;++i){unsigned char c=(unsigned char)target[i];if(c<32||c==127||c=='\\'){static const char hex[]="0123456789abcdef";escaped[o++]='\\';escaped[o++]='x';escaped[o++]=hex[c>>4];escaped[o++]=hex[c&15];}else escaped[o++]=(char)c;}
  escaped[o]=0;
  snprintf(line,sizeof line,"FD_ENTRY thread=%lu scan=%u fd=%s readlink_rc=%ld readlink_errno=%d target=%s\n",(unsigned long)pthread_self(),scan,e->d_name,(long)n,link_errno,escaped);emit(line);
 }
 errno=saved;return e;
}
int __wrap_closedir(DIR *d) {
 int tracked=d==observed;
 // No use of freed DIR after real_closedir.
 if(tracked)observed=NULL;
 int rc=__real_closedir(d);int saved=errno;
 if(tracked){char line[256];snprintf(line,sizeof line,"FD_SCAN_END thread=%lu scan=%u entries=%u closedir_rc=%d\n",(unsigned long)pthread_self(),scan,entries_seen,rc);emit(line);}
 errno=saved;return rc;
}
