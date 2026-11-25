#!/usr/bin/env python3
# nvn_vk_pipe_demand 的改坏版本生成器（用例必须能红）：$1=源文件 $2=输出文件 $3=变异名
import sys

MUTANTS = {
    # 去掉 wait 里的插队：当前帧要的管线不再被挪到队首
    'noprioritize': ('static void dem_prioritize(const struct dem_key *want) {', 'static void dem_prioritize(const struct dem_key *want) {\n    (void)want; return;   /* 变异：不插队 */'),
    # reap 不 join：池停下后 running 永远不清
    'noreap': ('            if (pthread_join(g_th[i], NULL) == 0) g_reaped[i] = 1; else pending++;',
               '            pending++;   /* 变异：不 join */'),
    # kick 不走 FOLLOW：同一个键会被建两次
    'nodup': ('    if (r == NVK_PP_ENTER_FOLLOW) {', '    if (0) {   /* 变异：不去重 */'),
}

def main():
    if len(sys.argv) != 4:
        print('usage: mutant.py <src> <out> <name>'); return 2
    src, out, name = sys.argv[1], sys.argv[2], sys.argv[3]
    if name not in MUTANTS:
        print('unknown mutant %s' % name); return 2
    text = open(src, encoding='utf-8').read()
    old, new = MUTANTS[name]
    if old not in text:
        print('mutant %s: anchor not found' % name); return 1
    open(out, 'w', encoding='utf-8').write(text.replace(old, new, 1))
    return 0

if __name__ == '__main__':
    sys.exit(main())