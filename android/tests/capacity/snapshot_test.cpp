#include "../../native/capacity_snapshot.h"
#include <cassert>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <string>
static void status(const char *root, const char *tid, const char *content) {
    std::string dir=std::string(root)+"/"+tid;
    assert(mkdir(dir.c_str(),0700)==0);
    FILE *f=std::fopen((dir+"/status").c_str(),"w"); assert(f);
    assert(std::fputs(content,f)>=0); assert(std::fclose(f)==0);
}
int main() {
    char root[]="/tmp/s2a-capacity-snapshot-XXXXXX"; assert(mkdtemp(root));
    status(root,"100","Name:\tworker\nCpus_allowed_list:\t0-3,6-7\n");
    status(root,"101","Name:\tmain\nCpus_allowed_list:\t7\n");
    auto good=s2a::read_affinity_snapshot(root);
    assert(good.seen==2 && good.errors==0 && !good.truncated && good.records.size()==2);
    bool full=false, single=false;
    for (const auto &r:good.records) { if(r.tid==100 && r.mask=="0-3,6-7" && r.name=="worker")full=true; if(r.tid==101 && r.mask=="7" && r.name=="main")single=true; }
    assert(full && single);
    status(root,"102","Name:\texited\n");
    auto missing=s2a::read_affinity_snapshot(root);
    assert(missing.seen==3 && missing.errors==1 && missing.records.size()==2);
    auto capped=s2a::read_affinity_snapshot(root,1);
    assert(capped.truncated && capped.seen==2 && capped.records.size()<=1);
    auto absent=s2a::read_affinity_snapshot("/no/such/s2a-task-root");
    assert(absent.errors==1 && absent.records.empty());
    return 0;
}
