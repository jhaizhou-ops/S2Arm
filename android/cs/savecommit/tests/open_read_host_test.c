// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 S2Arm contributors
// SPDX-License-Identifier: Apache-2.0
#define _GNU_SOURCE
#include "../../../native/s2a_savecommit.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int checks, failures, active, bad_flags, fail_stat, stat_failures, fake_success;
#define CHECK(expr) do { ++checks; if (!(expr)) { ++failures; fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#expr); } } while (0)
static void join(char out[4096],const char *a,const char *b) {
    if (snprintf(out,4096,"%s/%s",a,b)>=4096) abort();
}
static int fd_count(void) {
    DIR *d=opendir("/proc/self/fd");
    if (!d) abort();
    int n=0; struct dirent *e;
    while ((e=readdir(d))) if (strcmp(e->d_name,".")&&strcmp(e->d_name,"..")) ++n;
    if (closedir(d)) abort();
    return n;
}
int __real_open(const char *,int,...);
int __wrap_open(const char *path,int flags,...) {
    mode_t mode=0;
    if (flags&O_CREAT) { va_list ap; va_start(ap,flags); mode=va_arg(ap,int); va_end(ap); }
    if (active) {
        if ((flags&O_ACCMODE)!=O_RDONLY || !(flags&O_NOFOLLOW) || !(flags&O_NONBLOCK)) {
            ++bad_flags;
            /* Guard against hanging the test on an unsafe blocking FIFO open.
             * The test separately fails bad_flags; this does not mask a pass. */
            errno=EINVAL;
            return -1;
        }
    }
    return __real_open(path,flags,mode);
}
int __real_fstat(int,struct stat *);
int __wrap_fstat(int fd,struct stat *st) {
    if (active&&fail_stat) { ++stat_failures; errno=EIO; return -1; }
    return __real_fstat(fd,st);
}
int __real_s2a_savecommit_open_read(const char *,int *);
int __wrap_s2a_savecommit_open_read(const char *path,int *out) {
    if (fake_success) { if(out)*out=-1; return 0; }
    return __real_s2a_savecommit_open_read(path,out);
}
static int call(const char *path,int *fd) {
    active=1;
    int rc=s2a_savecommit_open_read(path,fd);
    active=0;
    return rc;
}
static void reject(const char *path) {
    int fd=12345;
    CHECK(call(path,&fd)>0);
    CHECK(fd==-1);
    if(fd>=0 && fd!=12345) close(fd);
}
int main(int argc,char **argv) {
    if(argc<2)return 2;
    fake_success=argc>2&&!strcmp(argv[2],"fake-open-success");
    char root[4096],regular[4096],link[4096],slash[4096],fifo[4096],missing[4096];
    join(root,argv[1],"openread-fixture-XXXXXX");
    if(!mkdtemp(root))return 2;
    join(regular,root,"regular"); join(link,root,"link"); join(fifo,root,"fifo"); join(missing,root,"absent");
    static const unsigned char expected[]={0,255,17,0,42,128};
    int writer=open(regular,O_CREAT|O_EXCL|O_WRONLY,0600);
    if(writer<0||write(writer,expected,sizeof expected)!=(ssize_t)sizeof expected||close(writer))abort();
    if(symlink(regular,link)||mkfifo(fifo,0600))abort();
    int baseline=fd_count(),fd=12345;
    CHECK(call(regular,&fd)==0);
    CHECK(fd>=0);
    if(fd>=0 && fd!=12345) {
        struct stat st;
        CHECK(fstat(fd,&st)==0&&S_ISREG(st.st_mode));
        unsigned char got[32]={0};
        CHECK(read(fd,got,sizeof got)==(ssize_t)sizeof expected);
        CHECK(!memcmp(got,expected,sizeof expected));
        CHECK((fcntl(fd,F_GETFL)&O_ACCMODE)==O_RDONLY);
        CHECK(write(fd,expected,1)==-1&&errno==EBADF);
        CHECK(close(fd)==0);
        CHECK(fcntl(fd,F_GETFD)==-1&&errno==EBADF);
    }
    CHECK(fd_count()==baseline);
    int owned=open(regular,O_RDONLY);
    CHECK(owned>=0);
    if(owned>=0) { CHECK(s2a_savecommit_close_fd(owned)==0); CHECK(fcntl(owned,F_GETFD)==-1&&errno==EBADF); }
    CHECK(s2a_savecommit_close_fd(-1)==EBADF);
    reject(link);
    join(slash,link,""); reject(slash);
    reject(root); reject(missing); reject(NULL); reject("relative");
    CHECK(call(regular,NULL)>0);
    struct timespec start,end;
    if(clock_gettime(CLOCK_MONOTONIC,&start))abort();
    reject(fifo);
    if(clock_gettime(CLOCK_MONOTONIC,&end))abort();
    double elapsed=(double)(end.tv_sec-start.tv_sec)+(double)(end.tv_nsec-start.tv_nsec)/1e9;
    /* Host regression budget only, not a product latency guarantee. */
    CHECK(elapsed<1.0);
    CHECK(fd_count()==baseline);
    fail_stat=1;fd=12345;
    CHECK(call(regular,&fd)==EIO);
    CHECK(fd==-1);
    fail_stat=0;
    CHECK(stat_failures==1);
    CHECK(fd_count()==baseline);
    for(int i=0;i<64;i++) {
        fd=12345;
        CHECK(call(regular,&fd)==0&&fd>=0&&fd!=12345);
        if(fd>=0&&fd!=12345)CHECK(close(fd)==0);
        reject(root); reject(link); reject(missing); reject(fifo);
        fail_stat=1;fd=12345;
        CHECK(call(regular,&fd)==EIO&&fd==-1);
        fail_stat=0;
    }
    CHECK(stat_failures==65);
    CHECK(bad_flags==0);
    CHECK(fd_count()==baseline);
    CHECK(unlink(regular)==0);CHECK(unlink(link)==0);CHECK(unlink(fifo)==0);CHECK(rmdir(root)==0);
    printf("OpenRead host: %d checks, %d failures; FIFO %.6f sec; fd baseline=%d final=%d; negative-control=%d\n",checks,failures,elapsed,baseline,fd_count(),fake_success);
    return failures?1:0;
}
