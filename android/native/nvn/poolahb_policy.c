#include "poolahb_policy.h"

int s2a_pa_select(const struct s2a_pa_candidate *c, int n, uint64_t min_bytes,
                  uint64_t max_len, uint64_t budget_left) {
    if (!c || n <= 0) return -1;
    int best = -1;
    uint64_t best_bytes = 0, best_len = 0;
    for (int i = 0; i < n; i++) {
        if (c[i].done || c[i].failed) continue;
        if (!c[i].len || c[i].len > max_len || c[i].len > budget_left) continue;
        if (c[i].bytes < min_bytes) continue;
        if (best < 0) { best = i; best_bytes = c[i].bytes; best_len = c[i].len; continue; }
        // bytes/len 比较用交叉相乘避免浮点：a.bytes * b.len vs b.bytes * a.len
        unsigned __int128 lhs = (unsigned __int128)c[i].bytes * best_len;
        unsigned __int128 rhs = (unsigned __int128)best_bytes * c[i].len;
        if (lhs > rhs || (lhs == rhs && c[i].bytes > best_bytes)) {
            best = i; best_bytes = c[i].bytes; best_len = c[i].len;
        }
    }
    return best;
}
