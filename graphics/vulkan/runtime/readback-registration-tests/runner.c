#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char**argv) {
    if(argc!=3)return 2;
    void*lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
    int(*test)(int)=(int(*)(int))dlsym(lib,"epoch_test");
    if(!test){fprintf(stderr,"%s\n",dlerror());return 2;}
    int result=test(atoi(argv[2]));printf("native-managed test exit %d\n",result);return result;
}
