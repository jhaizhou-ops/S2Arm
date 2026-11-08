// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <dirent.h>
#include "jni.h"
static const char *fault;
static int dup_calls,open_calls,dup2_calls,leases,releases,called,desired_rc,localrefs;
static int match(const char*s){return !strcmp(fault,s);}
static uid_t fake_getuid(void){return 10000;}
static int fake_lstat(const char*p,struct stat*s){int r=lstat(p,s);if(!r)s->st_uid=10000;return r;}
static int fake_stat(const char*p,struct stat*s){int r=stat(p,s);if(!r)s->st_uid=match("identity")?10001:10000;return r;}
static int fake_snprintf(char*p,size_t n,const char*f,...){if(match("path")&&!strcmp(f,"%s/status.txt"))return 4096;va_list a;va_start(a,f);int r=vsnprintf(p,n,f,a);va_end(a);return r;}
static FILE *fake_fopen(const char*p,const char*m){
 if(!strcmp(p,"/proc/self/attr/current")){if(match("context")){errno=EACCES;return NULL;}FILE*f=tmpfile();if(!f)abort();fputs("u:r:untrusted_app:s0\n",f);rewind(f);return f;}
 if(match("status")&&strstr(p,"/status.txt")){errno=EACCES;return NULL;}return fopen(p,m);
}
static int fake_dup(int fd){int k=++dup_calls;if((match("dup1")&&k==1)||(match("dup2")&&k==2)){errno=EMFILE;return -1;}return dup(fd);}
static int fake_open(const char*p,int flags,...){va_list a;va_start(a,flags);int mode=va_arg(a,int);va_end(a);int k=++open_calls;if((match("open1")&&k==1)||(match("open2")&&k==2)){errno=EACCES;return -1;}return open(p,flags,mode);}
static int fake_dup2(int a,int b){int k=++dup2_calls;if((match("redirect1")&&k==1)||(match("redirect2")&&k==2)){errno=EBADF;return -1;}return dup2(a,b);}
static const char *get_utf(JNIEnv*e,jstring s,void*v){(void)e;(void)v;if(match("utf"))return NULL;leases++;return s;}
static void release_utf(JNIEnv*e,jstring s,const char*p){(void)e;(void)s;(void)p;releases++;}
static jmethodID method(JNIEnv*e,jclass c,const char*n,const char*s){(void)e;(void)c;(void)n;(void)s;return match("method")?NULL:(void*)1;}
static jstring new_utf(JNIEnv*e,const char*s){(void)e;if(match("newutf"))return NULL;localrefs++;return s;}
static void callback(JNIEnv*e,jclass c,jmethodID m,jstring s){(void)e;(void)c;(void)m;(void)s;}
static void delete_ref(JNIEnv*e,jstring s){(void)e;(void)s;localrefs--;}
static int exception(JNIEnv*e){(void)e;return match("callback");}
int suite_main(int argc,char**argv){if(argc!=2||!argv[1])abort();called++;printf("synthetic suite rc=%d\n",desired_rc);return desired_rc;}
#define getuid fake_getuid
#define lstat fake_lstat
#define stat(p,s) fake_stat(p,s)
#define snprintf fake_snprintf
#define fopen fake_fopen
#define dup fake_dup
#define open fake_open
#define dup2 fake_dup2
#define JNI_ENTRY tested_entry
#ifndef RUNNER_SOURCE
#define RUNNER_SOURCE "../native/runner.c"
#endif
#include RUNNER_SOURCE
#undef getuid
#undef lstat
#undef stat
#undef snprintf
#undef fopen
#undef dup
#undef open
#undef dup2
static int count(void){DIR*d=opendir("/proc/self/fd");if(!d)abort();int n=0;struct dirent*e;while((e=readdir(d)))if(strcmp(e->d_name,".")&&strcmp(e->d_name,".."))n++;closedir(d);return n;}
static int checks;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FAIL case=%s line=%d expr=%s\n",fault,__LINE__,#x);exit(1);}}while(0)
int main(void){
 struct JNITest table={get_utf,release_utf,method,new_utf,callback,delete_ref,exception};JNIEnv env=&table;
 const char *cases[]={"utf","method","newutf","callback","path","status","dup1","dup2","open1","open2","redirect1","redirect2","identity","context","success","suitefailure"};
 const int codes[]={-102,-108,-109,-110,-104,-105,-106,-106,-106,-106,-107,-107,-103,75,0,7};
 for(unsigned i=0;i<sizeof cases/sizeof cases[0];i++){
  fault=cases[i];dup_calls=open_calls=dup2_calls=leases=releases=called=localrefs=once=0;desired_rc=match("suitefailure")?7:0;
  char root[]="/tmp/s2arm-cleanup-unit-XXXXXX";CHECK(mkdtemp(root)!=NULL);printf("fixture=%s\n",root);fflush(stdout);
  struct stat out_before,err_before,out_after,err_after;CHECK(fstat(1,&out_before)==0);CHECK(fstat(2,&err_before)==0);int baseline=count();
  int rc=tested_entry(&env,NULL,root);
  CHECK(rc==codes[i]);CHECK(leases==releases);CHECK(localrefs==0);CHECK(count()==baseline);
  CHECK(fstat(1,&out_after)==0);CHECK(fstat(2,&err_after)==0);
  CHECK(out_before.st_dev==out_after.st_dev&&out_before.st_ino==out_after.st_ino);CHECK(err_before.st_dev==err_after.st_dev&&err_before.st_ino==err_after.st_ino);
  CHECK(called==(match("success")||match("suitefailure")));
  char p[4096];const char*files[]={"status.txt","stdout.log","stderr.log"};
  snprintf(p,sizeof p,"%s/status.txt",root);FILE *status=fopen(p,"r");
  if(status){char text[4096];size_t n=fread(text,1,sizeof text-1,status);text[n]=0;fclose(status);if(match("success")||match("suitefailure"))CHECK(strstr(text,"state=RETURNED")!=NULL);else if(match("context"))CHECK(strstr(text,"state=ENV_NOT_READY")!=NULL);else CHECK(strstr(text,"state=WRAPPER_ERROR")!=NULL);}
  for(int j=0;j<3;j++){snprintf(p,sizeof p,"%s/%s",root,files[j]);if(unlink(p)&&errno!=ENOENT)abort();}CHECK(rmdir(root)==0);
  printf("case=%s rc=%d fd_baseline=%d fd_final=%d PASS\n",fault,rc,baseline,count());
 }
 printf("PASS %d checks; host fake-JNI/domain identity only, not Android execution\n",checks);return 0;
}
