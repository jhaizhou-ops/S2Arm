#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Execute the production frames writer bodies with real pthreads, no Apple SDK."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'graphics/nvn/host_adapt.m'
PRE = r'''
#define _POSIX_C_SOURCE 200809L
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
static int g_ft_fd = -1, notify_wait, notice[2], short_writes, block_write, release_write[2], joining[2], observe_join;
static void cutoff(int sig) { (void)sig; _exit(124); }
static int observed_wait(pthread_cond_t *c, pthread_mutex_t *m) {
    if (notify_wait) { notify_wait=0; if(write(notice[1], "w", 1)!=1) _exit(90); }
    return pthread_cond_wait(c,m);
}
static ssize_t observed_write(int fd, const void *p, size_t n) {
    if(block_write) {
        block_write=0; if(write(notice[1],"b",1)!=1) _exit(91);
        char c; if(read(release_write[0],&c,1)!=1) _exit(92);
    }
    if(short_writes && n>3) n=3;
    return write(fd,p,n);
}
static int observed_join(pthread_t t, void **r) {
    if(observe_join && write(joining[1],"j",1)!=1) _exit(93);
    return pthread_join(t,r);
}
#define pthread_join observed_join
#define pthread_cond_wait observed_wait
#define pthread_setname_np(n) ((void)(n))
#define write observed_write
#define LOG(...) ((void)0)
'''
POST = r'''
#undef write
#undef pthread_cond_wait
#undef pthread_join
static void check(int ok, const char *why) { if(!ok) { fprintf(stderr,"FAIL %s\n",why); exit(1); } }
static void wait_idle(void) {
    char c; check(read(notice[0],&c,1)==1,"wait notification");
    /* Acquiring this mutex proves observed_wait entered real cond_wait. */
    pthread_mutex_lock(&g_ftb_mu); pthread_mutex_unlock(&g_ftb_mu);
}
static void *exit_thread(void *unused) { (void)unused; ft_exit_flush(); return NULL; }
int main(int argc, char **argv) {
    check(argc==2,"case"); signal(SIGALRM,cutoff); alarm(3);
    FILE *file=tmpfile(); check(file!=NULL,"tmpfile"); g_ft_fd=fileno(file);
    check(pipe(notice)==0,"pipe");
    if(!strcmp(argv[1],"no-writer")) { ft_exit_flush(); puts("PASS no-writer"); return 0; }
    if(!strcmp(argv[1],"idle")) {
        notify_wait=1; start_writer(); wait_idle(); ft_exit_flush();
    } else if(!strcmp(argv[1],"ordered") || !strcmp(argv[1],"partial")) {
        const char *rows="0001\talpha\n0002\tbeta\n0003\tgamma\n";
        short_writes=!strcmp(argv[1],"partial");
        ft_put(rows,strlen(rows)); start_writer(); ft_exit_flush();
        char out[128]={0}; check(lseek(g_ft_fd,0,SEEK_SET)==0,"rewind");
        check(read(g_ft_fd,out,sizeof out)==(ssize_t)strlen(rows),"drain size");
        check(!strcmp(out,rows),"drain order and bytes");
    } else if(!strcmp(argv[1],"inflight")) {
        check(pipe(release_write)==0 && pipe(joining)==0,"gates");
        block_write=1; ft_put("first\n",6); start_writer();
        char c; check(read(notice[0],&c,1)==1,"writer in write");
        ft_put("second\n",7); observe_join=1;
        pthread_t exiting; check(!pthread_create(&exiting,NULL,exit_thread,NULL),"exit thread");
        check(read(joining[0],&c,1)==1,"exit reached real join");
        check(write(release_write[1],"r",1)==1,"release write"); pthread_join(exiting,NULL);
        char out[32]={0}; check(lseek(g_ft_fd,0,SEEK_SET)==0,"rewind");
        check(read(g_ft_fd,out,sizeof out)==13 && !strcmp(out,"first\nsecond\n"),"inflight then queued order");
    } else if(!strcmp(argv[1],"repeated")) {
        notify_wait=1; start_writer(); wait_idle();
        pthread_t a,b; check(!pthread_create(&a,NULL,exit_thread,NULL),"exit a");
        check(!pthread_create(&b,NULL,exit_thread,NULL),"exit b");
        pthread_join(a,NULL); pthread_join(b,NULL); ft_exit_flush();
    } else if(!strcmp(argv[1],"late-put")) {
        notify_wait=1; start_writer(); wait_idle(); ft_exit_flush();
        ft_put("late",4); check(g_ftb_n==0,"closed queue rejects late row");
    } else return 2;
    puts("PASS"); return 0;
}
'''

def bodies(text):
    block=text[text.index('#define FT_BUF '):text.index('static void ft_open(void)')]
    start=text.index('    { pthread_t th;',text.index('static void ft_open(void)'))
    depth=0
    for end in range(start,len(text)):
        if text[end]=='{': depth+=1
        elif text[end]=='}':
            depth-=1
            if depth==0: break
    return PRE+block+'\nstatic void start_writer(void) '+text[start:end+1]+'\n'+POST

def compile_run(text, cases, tmp, label):
    c=tmp/(label+'.c'); exe=tmp/label; c.write_text(bodies(text))
    subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror',
                    '-Wno-unused-function','-pthread',str(c),'-o',str(exe)],check=True)
    results=[]
    for case in cases:
        run=subprocess.run([str(exe),case],capture_output=True,text=True,timeout=6)
        print(label,case,'exit',run.returncode,run.stdout.strip(),run.stderr.strip(),flush=True)
        results.append(run.returncode)
    return results

text=SOURCE.read_text()
with tempfile.TemporaryDirectory(prefix='frames-writer-') as path:
    tmp=Path(path)
    cases=['no-writer','idle','ordered','partial','inflight','repeated','late-put']
    result=compile_run(text,cases,tmp,'production')
    if any(result): raise SystemExit(1)
    if 'g_ft_stop' in text:
        mutants=[('no-wake','pthread_cond_broadcast(&g_ftb_cv);','/* missing wake */','idle'),
                 ('no-join','int e = pthread_join(g_ft_thread, NULL);','int e = 0;','inflight'),
                 ('late-admit','!g_ft_stop && g_ftb_n + n <= FT_BUF','g_ftb_n + n <= FT_BUF','late-put')]
        for name,old,new,case in mutants:
            assert old in text, name
            rc=compile_run(text.replace(old,new,1),[case],tmp,name)[0]
            assert rc != 0, name+' did not fail'
print('frames writer: 7 scenarios and 3 negative controls passed')
