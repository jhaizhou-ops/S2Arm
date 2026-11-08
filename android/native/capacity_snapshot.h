// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <dirent.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace s2a {
struct DirClose { void operator()(DIR *p) const { (void)closedir(p); } };
struct FileClose { void operator()(FILE *p) const { (void)std::fclose(p); } };
struct AffinityRecord { unsigned long tid; std::string mask; std::string name; };
struct AffinitySnapshot { unsigned seen=0, errors=0; bool truncated=false; std::vector<AffinityRecord> records; };
inline AffinitySnapshot read_affinity_snapshot(const char *root, unsigned limit=256) {
    AffinitySnapshot result;
    std::unique_ptr<DIR,DirClose> dir(opendir(root));
    if (!dir) { result.errors++; return result; }
    for (;;) {
        errno=0; dirent *entry=readdir(dir.get());
        if (!entry) { if(errno)result.errors++; break; }
        char *end=nullptr; unsigned long tid=std::strtoul(entry->d_name,&end,10);
        if (!entry->d_name[0] || !end || *end || !tid) continue;
        ++result.seen;
        if (result.seen>limit) { result.truncated=true; break; }
        char path[512];
        int n=std::snprintf(path,sizeof(path),"%s/%s/status",root,entry->d_name);
        if(n<0 || static_cast<size_t>(n)>=sizeof(path)) { ++result.errors; continue; }
        std::unique_ptr<FILE,FileClose> f(std::fopen(path,"r")); if(!f) { ++result.errors; continue; }
        char line[512]; bool found=false; std::string name="unknown", mask;
        while(std::fgets(line,sizeof(line),f.get())) {
            const char *name_label="Name:";
            if (!std::strncmp(line,name_label,std::strlen(name_label))) {
                char *value=line+std::strlen(name_label); while(*value==' ' || *value=='\t') ++value;
                size_t length=std::strcspn(value,"\r\n"); if(length && length<64) { name.assign(value,length); for (char &c:name) if (c==':' || c==';' || c==' ' || c=='\t') c='_'; }
                continue;
            }
            const char *label="Cpus_allowed_list:";
            if(std::strncmp(line,label,std::strlen(label))) continue;
            char *value=line+std::strlen(label); while(*value==' ' || *value=='\t') ++value;
            size_t length=std::strcspn(value,"\r\n");
            if(length && length<128 && (value[length]=='\r' || value[length]=='\n')) {
                mask.assign(value,length); found=true;
            }
            break;
        }
        if(std::ferror(f.get())) found=false;
        if(!found) ++result.errors; else result.records.push_back({tid,mask,name});
    }
    return result;
}
}
