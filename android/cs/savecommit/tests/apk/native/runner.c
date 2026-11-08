// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#define _GNU_SOURCE
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <string.h>
#include <errno.h>
#include "owned_directory.h"
#ifndef JNI_ENTRY
#error JNI_ENTRY required
#endif
// Build records the exact source identity; no historical hard-coded test head.
#ifndef S2ARM_SOURCE_COMMIT
#define S2ARM_SOURCE_COMMIT "unknown"
#endif
extern int suite_main(int,char**);
static int once;
JNIEXPORT jint JNICALL JNI_ENTRY(JNIEnv *env,jclass cls,jstring owned) {
 int rc=-102,suite_returned=0,redirected_out=0,redirected_err=0,cleanup_failed=0;
 int saved_out=-1,saved_err=-1,out=-1,err=-1;
 FILE *status=NULL;
 (void)cls;
 if(once++)return -101;
 const char*dir=(*env)->GetStringUTFChars(env,owned,NULL);if(!dir)return -102;
 char actual[4096]={0};struct stat st;memset(&st,0,sizeof st);
 errno=0;char *resolved=realpath(dir,actual);int realpath_errno=errno;
 int same=resolved ? strcmp(actual,dir)==0 : 0;
 errno=0;int lstat_rc=lstat(dir,&st);int lstat_errno=errno;
 int is_directory=lstat_rc==0 && S_ISDIR(st.st_mode);
 int owned_by_uid=lstat_rc==0 && st.st_uid==getuid();
 struct stat canonical;memset(&canonical,0,sizeof canonical);
 errno=0;int canonical_rc=resolved ? stat(actual,&canonical) : -1;int canonical_errno=errno;
 int identity_ok=resolved && lstat_rc==0 && canonical_rc==0 && owned_directory_identity(&st,&canonical,getuid());
 char diagnostic[10000];
 snprintf(diagnostic,sizeof diagnostic,
  "state=NATIVE_GUARD_DIAGNOSTIC\ninput=%s\nrealpath_ok=%d\nrealpath_errno=%d\nrealpath_result=%s\nstring_equal=%d\nlstat_rc=%d\nlstat_errno=%d\nst_mode=%lo\nst_uid=%ld\ngetuid=%ld\nis_directory=%d\nowned_by_uid=%d\ncanonical_stat_rc=%d\ncanonical_errno=%d\ncanonical_mode=%lo\ncanonical_uid=%ld\noriginal_dev=%llu\noriginal_ino=%llu\ncanonical_dev=%llu\ncanonical_ino=%llu\nidentity_ok=%d",
  dir,resolved!=NULL,realpath_errno,actual,same,lstat_rc,lstat_errno,
  (unsigned long)st.st_mode,(long)st.st_uid,(long)getuid(),is_directory,owned_by_uid,canonical_rc,canonical_errno,(unsigned long)canonical.st_mode,(long)canonical.st_uid,
  (unsigned long long)st.st_dev,(unsigned long long)st.st_ino,(unsigned long long)canonical.st_dev,(unsigned long long)canonical.st_ino,identity_ok);
 jmethodID evidence=(*env)->GetStaticMethodID(env,cls,"nativeEvidence","(Ljava/lang/String;)V");
 if(!evidence){rc=-108;goto cleanup;}
 jstring report=(*env)->NewStringUTF(env,diagnostic);
 if(!report){rc=-109;goto cleanup;}
 (*env)->CallStaticVoidMethod(env,cls,evidence,report);(*env)->DeleteLocalRef(env,report);
 if((*env)->ExceptionCheck(env)){rc=-110;goto cleanup;}
 // Android ancestor aliases are allowed only after directory identity/ownership verification.
 if(!identity_ok){rc=-103;goto cleanup;}
 char path[4096];
 if(snprintf(path,sizeof path,"%s/status.txt",actual)>=(int)sizeof path){rc=-104;goto cleanup;}
 status=fopen(path,"wx");if(!status){rc=-105;goto cleanup;}
 char context[256]="unreadable";FILE*f=fopen("/proc/self/attr/current","r");if(f){if(!fgets(context,sizeof context,f))snprintf(context,sizeof context,"unreadable");fclose(f);}
 struct statfs fs;memset(&fs,0,sizeof fs);int fsrc=statfs(actual,&fs);
 fprintf(status,"state=STARTED\nsource_commit=%s\nuid=%ld\npid=%ld\nselinux=%s\nfilesystem_rc=%d\nfilesystem_type=0x%lx\n",S2ARM_SOURCE_COMMIT,(long)getuid(),(long)getpid(),context,fsrc,(unsigned long)fs.f_type);fflush(status);fsync(fileno(status));
 if(getuid()<10000 || !strstr(context,"untrusted_app")){fprintf(status,"state=ENV_NOT_READY\nreason=requires_untrusted_app_domain\n");fflush(status);fsync(fileno(status));rc=75;goto cleanup;}
 saved_out=dup(STDOUT_FILENO);saved_err=dup(STDERR_FILENO);
 snprintf(path,sizeof path,"%s/stdout.log",actual);out=open(path,O_CREAT|O_EXCL|O_WRONLY,0600);
 snprintf(path,sizeof path,"%s/stderr.log",actual);err=open(path,O_CREAT|O_EXCL|O_WRONLY,0600);
 if(out<0||err<0||saved_out<0||saved_err<0){rc=-106;goto cleanup;}
 fflush(NULL);
 if(dup2(out,STDOUT_FILENO)<0){rc=-107;goto cleanup;}redirected_out=1;
 if(dup2(err,STDERR_FILENO)<0){rc=-107;goto cleanup;}redirected_err=1;
 setvbuf(stdout,NULL,_IONBF,0);setvbuf(stderr,NULL,_IONBF,0);
 char*argv[]={"original-native-suite",actual,NULL};
 rc=suite_main(2,argv);suite_returned=1;
 fflush(stdout);fflush(stderr);fsync(out);fsync(err);
cleanup:
 // Only release resources acquired by this invocation. Original suite rc is retained.
 if(redirected_out) {fflush(stdout);if(dup2(saved_out,STDOUT_FILENO)<0){cleanup_failed=1;if(status)fprintf(status,"cleanup_restore_stdout_errno=%d\n",errno);}}
 if(redirected_err) {fflush(stderr);if(dup2(saved_err,STDERR_FILENO)<0){cleanup_failed=1;if(status)fprintf(status,"cleanup_restore_stderr_errno=%d\n",errno);}}
 if(saved_out>=0)close(saved_out);
 if(saved_err>=0)close(saved_err);
 if(out>=0)close(out);
 if(err>=0)close(err);
 if(status) {
  if(cleanup_failed)fprintf(status,"state=CLEANUP_ERROR\noriginal_return_code=%d\n",rc);
  else if(suite_returned)fprintf(status,"state=RETURNED\nsuite_return_code=%d\n",rc);
  else if(rc<0)fprintf(status,"state=WRAPPER_ERROR\nwrapper_return_code=%d\n",rc);
  fflush(status);fsync(fileno(status));fclose(status);
 }
 (*env)->ReleaseStringUTFChars(env,owned,dir);return rc;
}
