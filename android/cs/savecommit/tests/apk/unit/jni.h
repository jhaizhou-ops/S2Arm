// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef TEST_JNI_H
#define TEST_JNI_H
// Minimal host-only JNI test double. Not used by an Android build.
typedef int jint;typedef void *jclass;typedef const char *jstring;typedef void *jmethodID;
struct JNITest;typedef const struct JNITest *JNIEnv;
struct JNITest {
 const char *(*GetStringUTFChars)(JNIEnv *,jstring,void *);
 void (*ReleaseStringUTFChars)(JNIEnv *,jstring,const char *);
 jmethodID (*GetStaticMethodID)(JNIEnv *,jclass,const char *,const char *);
 jstring (*NewStringUTF)(JNIEnv *,const char *);
 void (*CallStaticVoidMethod)(JNIEnv *,jclass,jmethodID,jstring);
 void (*DeleteLocalRef)(JNIEnv *,jstring);
 int (*ExceptionCheck)(JNIEnv *);
};
#define JNIEXPORT
#define JNICALL
#endif
