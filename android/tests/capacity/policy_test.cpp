#include "../../native/capacity_policy.h"
#include <cassert>
using s2a::CpuCapacity;
int main() {
    using s2a::highest_capacity_cpus;
    assert(highest_capacity_cpus({}).empty());
    assert(highest_capacity_cpus({{2,512},{7,0}}).empty());
    assert(highest_capacity_cpus({{2,512},{7,512}}).empty());
    assert((highest_capacity_cpus({{1,700},{6,1000},{7,1000},{18,100}})==std::vector<unsigned>{6,7}));
    assert((highest_capacity_cpus({{123,1024},{2,128},{88,1024}})==std::vector<unsigned>{123,88}));
    using s2a::capacity_cpus;
    const std::vector<CpuCapacity> three{{0,256},{1,512},{6,1024},{7,1024}};
    assert((capacity_cpus(three,"split",0)==std::vector<unsigned>{7}));
    assert((capacity_cpus(three,"split",1)==std::vector<unsigned>{6}));
    assert((capacity_cpus(three,"split2",1)==std::vector<unsigned>{6}));
    assert((capacity_cpus({{0,256},{6,512},{7,1024}},"split",1)==std::vector<unsigned>{6}));
    assert((capacity_cpus(three,"top2grp",0)==std::vector<unsigned>{7,6,1}));
    assert(capacity_cpus({{0,512}},"split",0).empty());
    assert(capacity_cpus({{0,0},{1,512}},"split",0).empty());
    assert(capacity_cpus(three,"bad",0).empty());
}
