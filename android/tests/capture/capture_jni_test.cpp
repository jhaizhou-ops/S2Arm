// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "capture_jpeg.h"
#include <jni.h>
#include <cassert>
#include <cerrno>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>
int main(int argc,char **argv) {
    assert(argc==3);
    std::vector<uint8_t> rgba(64*48*4);
    for(int y=0;y<48;y++)for(int x=0;x<64;x++){
        int i=(y*64+x)*4,q=(y>=24)*2+(x>=32);
        rgba[i]=(q==0||q==3)?255:0;rgba[i+1]=(q==1||q==3)?255:0;
        rgba[i+2]=(q==2||q==3)?255:0;rgba[i+3]=255;
    }
    uint8_t *jpeg=reinterpret_cast<uint8_t*>(1);uint64_t bytes=9;
    assert(s2a_android_encode_jpeg(rgba.data(),rgba.size(),64,48,95,&jpeg,&bytes)==ENODEV&&!jpeg&&bytes==0);
    JavaVM *vm=nullptr;JNIEnv *env=nullptr;
    std::string cp="-Djava.class.path="+std::string(argv[1]),tmp="-Djava.io.tmpdir="+std::string(argv[2]);
    std::string err="-XX:ErrorFile="+std::string(argv[2])+"/jvm-error-%p.log";
    JavaVMOption options[6]{};
    const char *values[]={cp.c_str(),tmp.c_str(),"-Djava.awt.headless=true","-XX:-UsePerfData","-Xcheck:jni",err.c_str()};
    for(int i=0;i<6;i++)options[i].optionString=const_cast<char*>(values[i]);
    JavaVMInitArgs args{};args.version=JNI_VERSION_1_6;args.nOptions=6;args.options=options;
    assert(JNI_CreateJavaVM(&vm,reinterpret_cast<void**>(&env),&args)==JNI_OK);
    jclass codec=env->FindClass("org/s2arm/android/JvmCaptureCodec");assert(codec&&!env->ExceptionCheck());
    jclass wrong=env->FindClass("java/lang/String");assert(wrong&&!env->ExceptionCheck());
    assert(s2a_android_capture_init(nullptr,codec)==EINVAL);
    assert(s2a_android_capture_init(env,wrong)==EINVAL&&!env->ExceptionCheck());
    assert(s2a_android_capture_init(env,codec)==0);assert(s2a_android_capture_init(env,codec)==0);
    assert(s2a_android_capture_init(env,wrong)==EALREADY);
    assert(s2a_android_encode_jpeg(rgba.data(),1,64,48,80,&jpeg,&bytes)==EINVAL&&!jpeg&&bytes==0);
    assert(s2a_android_encode_jpeg(nullptr,rgba.size(),64,48,80,&jpeg,&bytes)==EINVAL);
    assert(s2a_android_encode_jpeg(rgba.data(),rgba.size(),64,48,101,&jpeg,&bytes)==EINVAL);
    assert(s2a_android_encode_jpeg(rgba.data(),rgba.size(),64,48,-1,&jpeg,&bytes)==EINVAL);
    assert(s2a_android_encode_jpeg(rgba.data(),rgba.size(),0,48,80,&jpeg,&bytes)==EINVAL);
    assert(s2a_android_encode_jpeg(rgba.data(),rgba.size(),64,48,95,&jpeg,&bytes)==0&&jpeg&&bytes>4);
    std::string reference=std::string(argv[2])+"/capture-reference.jpg";
    FILE *file=std::fopen(reference.c_str(),"wb");assert(file);
    assert(std::fwrite(jpeg,1,static_cast<size_t>(bytes),file)==bytes);assert(std::fclose(file)==0);
    jbyteArray encoded=env->NewByteArray(static_cast<jsize>(bytes));
    env->SetByteArrayRegion(encoded,0,static_cast<jsize>(bytes),reinterpret_cast<jbyte*>(jpeg));
    s2a_android_free_jpeg(jpeg);jpeg=nullptr;s2a_android_free_jpeg(nullptr);
    jmethodID verify=env->GetStaticMethodID(codec,"verify","([BII)Z");assert(verify&&!env->ExceptionCheck());
    bool correct=env->CallStaticBooleanMethod(codec,verify,encoded,64,48);assert(!env->ExceptionCheck()&&correct);
    env->DeleteLocalRef(encoded);
    JNIEnv *attached=nullptr;assert(vm->GetEnv(reinterpret_cast<void**>(&attached),JNI_VERSION_1_6)==JNI_OK&&attached==env);
    jmethodID mode=env->GetStaticMethodID(codec,"setMode","(I)V");assert(mode&&!env->ExceptionCheck());
    for(int m=1;m<=3;m++){
        env->CallStaticVoidMethod(codec,mode,m);assert(!env->ExceptionCheck());
        jpeg=reinterpret_cast<uint8_t*>(1);bytes=9;
        int rc=s2a_android_encode_jpeg(rgba.data(),rgba.size(),64,48,95,&jpeg,&bytes);
        assert(rc==(m==3?EBADMSG:EIO)&&!jpeg&&bytes==0&&!env->ExceptionCheck());
    }
    env->CallStaticVoidMethod(codec,mode,0);assert(!env->ExceptionCheck());
    std::vector<std::thread> threads;
    for(int t=0;t<4;t++)threads.emplace_back([&]{
        JNIEnv *thread_env=nullptr;
        assert(vm->GetEnv(reinterpret_cast<void**>(&thread_env),JNI_VERSION_1_6)==JNI_EDETACHED);
        for(int i=0;i<25;i++){
            uint8_t *out=nullptr;uint64_t n=0;
            assert(s2a_android_encode_jpeg(rgba.data(),rgba.size(),64,48,i%2?0:100,&out,&n)==0&&out&&n>4);
            s2a_android_free_jpeg(out);
            assert(vm->GetEnv(reinterpret_cast<void**>(&thread_env),JNI_VERSION_1_6)==JNI_EDETACHED);
        }
    });
    for(auto &thread:threads)thread.join();
    assert(!env->ExceptionCheck());
    env->DeleteLocalRef(codec);env->DeleteLocalRef(wrong);
    assert(vm->DestroyJavaVM()==JNI_OK);
    std::puts("JNI real JPEG: dimensions/quadrant colors, failures, caller attachment, 4x25 detached-thread lifecycles passed");
}
