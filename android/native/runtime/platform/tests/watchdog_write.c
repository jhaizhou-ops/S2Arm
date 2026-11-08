
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <string.h>
#include <time.h>
ssize_t __real_write(int fd,const void *buf,size_t n);
ssize_t __wrap_write(int fd,const void *buf,size_t n) {
    struct stat st;
    static const char marker[]="原生兜底";
    if (memmem(buf,n,marker,sizeof marker-1) && !fstat(fd,&st) && S_ISREG(st.st_mode)) {
        static const char msg[]="INJECT regular-file watchdog write blocks, O_NONBLOCK=";
        __real_write(1,msg,sizeof msg-1);
        const char *value=(fcntl(fd,F_GETFL)&O_NONBLOCK)?"1\n":"0\n";
        __real_write(1,value,2);
        struct timespec delay={10,0};
        nanosleep(&delay,0);
    }
    return __real_write(fd,buf,n);
}
