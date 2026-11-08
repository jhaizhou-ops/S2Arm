# 改写器回归语料（#149 / #58 H04）：跳转表与改写窗口的合成形态，不用任何游戏文件。tests/rewrite_corpus/run.py 读这份表。
# 每例：一段汇编（clang 汇编，放在代码段 0x100 起，下面注释里的地址都是绝对地址），ro 段 0x1000 起的表数据，手算期望。
#   期望 br    = {br 地址: 落点集合}：改写块里所有跳回原映像的直接跳转目标恰好等于这个集合（与改写器选哪种分派策略无关）；
#                写成 (必含, 至多) 时：必含 ⊆ 落点 ⊆ 至多——按表内容算的精确集合与「按下标位宽全铺」的阶梯超集都对（例 11）
#   期望 dyn   = [地址]：该处改写块按运行时值跳（尾调用 / blr），不应有跳回原映像的直接跳转
#   期望 gap   = [(地址, 种类)]：应拒绝（记缺口、退出码 3、不出映像）
#   期望 stat  = {统计项: 个数}：改写器结论行里的计数（窗口类形态用）
#   text       = 代码段长（缺省 0x1000）：落点超出 4 KB 的用例放大，让原目标都在映像内、不与补丁区地址重叠（真实游戏映像几十 MB，不会重叠）；
#                ro 段紧跟代码段，放大后 adrp 页号按 ro 段新位置手填
#   known      = 当前 main 上仍是缺口时写修复出处（'#137'，或「未见于实测游戏」这类不修的说明）；STRICT=1 时一律按期望判
# 相对表项 = 目标 − 表基址；表后接 0（目标 = 表基址，在 ro 段、出函数）或明显出函数的哨兵，超集识别读到即停。
# adrp 的页号手填（代码都在第 0 页、表在 0x1000 页：immlo = 1）：adrp x11 = 0xb000000b，x13 = 0xb000000d，x15 = 0xb000000f，x17 = 0xb0000011，x18 = 0xb0000012
T = 0x1000   # ro 段基址

def rel(base, *tg): return ('i32', [t - base for t in tg] + [0])

CASES = [
dict(name='01_byte_adr_ladder', doc='字节表（adr 阶梯，近）：adr x18,L / ldrb w9 / add x18,x18,x9,lsl#2 / br。下标 0..255 都可能 → 256 个落点 0x110 + 4i',
     asm='''
      adr x18, L
      ldrb w9, [x1, x2]
      add x18, x18, x9, lsl #2
      br x18
L:    ret
''', br={0x10c: {0x110 + 4 * i for i in range(256)}}),

dict(name='02_half_adr_ladder', doc='半字表（adr 阶梯，近）：同上换 ldrh → 65536 个落点 0x110 + 4i（代码段放大到 0x410000，落点都在映像内）', text=0x410000,
     asm='''
      adr x18, L
      ldrh w9, [x1, x2]
      add x18, x18, x9, lsl #2
      br x18
L:    ret
''', br={0x10c: {0x110 + 4 * i for i in range(65536)}}),

dict(name='03_word_rel_classic', doc='字表·相对（经典）：adrp/add x13 → 0x1800；cmp w18,#2 / b.hi；ldrsw x18,[x13,x18,lsl#2] / add x18,x18,x13 / br(0x118) → 0x11c / 0x124 / 0x12c',
     asm='''
      .inst 0xb000000d
      add x13, x13, #0x800
      cmp w18, #2
      b.hi out
      ldrsw x18, [x13, x18, lsl #2]
      add x18, x18, x13
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x11c, 0x124, 0x12c)}, br={0x118: {0x11c, 0x124, 0x12c}}),

dict(name='03c_word_rel_mid_x16_x17', doc='字表·相对（一般形态，10-26 普查 010095300B6A4000 / 0100C1F0051B6000）：表基址 adrp/add x18 → 0x1800、ldrsw x6,[x18,x8,lsl#2] / add x18,x6,x18，取表与 br 之间编译器排了 movk w16、mov w17（落点要读）→ 这两条随桩搬走、x16/x17 新值在落点还原；br(0x128) → 0x12c / 0x134 / 0x13c',
     asm='''
      cmp w8, #2
      b.hi out
      .inst 0xb0000012
      add x18, x18, #0x800
      mov w16, #0xfff0000
      ldrsw x6, [x18, x8, lsl #2]
      movk w16, #0xffc9
      mov w17, #0x30
      add x18, x6, x18
      and w11, w4, #0x800
      br x18
      add x0, x16, x17
      ret
      add x0, x16, x17
      ret
      add x0, x16, x17
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x12c, 0x134, 0x13c)}, br={0x128: {0x12c, 0x134, 0x13c}}),

dict(name='03d_word_rel_base_copy_sp_mids', doc='字表·相对（一般形态，11-02 普查女神异闻录5 乱战 01001C400E9D8000 main 0x494864–0x4948e0）：表基址 adrp/add x10 → 0x1800、ldrsw x9,[x10,x9,lsl#2]，'
         '基址先 mov x12,x10 拷走、x10 随即被 mov w10,w0 另作他用、add x18,x9,x12；取表与 br 之间排了 stp / str 到 [sp,#正偏移]（安卓分派块 sub sp,#32，搬来的偏移要 +32）→ br(0x128) → 0x12c / 0x134 / 0x13c',
     asm='''
      cmp w9, #2
      b.hi out
      .inst 0xb000000a
      add x10, x10, #0x800
      ldrsw x9, [x10, x9, lsl #2]
      stp w0, w0, [sp, #0x44]
      mov x12, x10
      mov w10, w0
      add x18, x9, x12
      str w0, [sp, #0x78]
      br x18
      mov w0, #1
      ret
      mov w0, #2
      ret
      mov w0, #3
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x12c, 0x134, 0x13c)}, br={0x128: {0x12c, 0x134, 0x13c}}),

dict(name='03h_word_rel_base_copy_before_ldrsw', doc='字表·相对（11-04 普查文明6 010044500C182000 main 0x10f338c–0x10f33a0，6 处同形）：表基址 adrp/add x18 → 0x1800，'
         '先 mov x6,x18 拷走、ldrsw x18,[x18,x10,lsl#2] 把表项写回 x18 本身、add x18,x18,x6 → br(0x11c) → 0x120 / 0x128 / 0x130',
     asm='''
      cmp w10, #2
      b.hi out
      .inst 0xb0000012
      add x18, x18, #0x800
      mov x6, x18
      ldrsw x18, [x18, x10, lsl #2]
      add x18, x18, x6
      br x18
      mov w0, #1
      ret
      mov w0, #2
      ret
      mov w0, #3
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x120, 0x128, 0x130)}, br={0x11c: {0x120, 0x128, 0x130}}),

dict(name='03i_base_copy_before_then_moved', doc='反例：mov x6,x18 之后、ldrsw 之前基址又被改（add x18,x18,#8）→ x6 不是 ldrsw 用的表基址，br(0x120) 报缺口',
     asm='''
      cmp w10, #2
      b.hi out
      .inst 0xb0000012
      add x18, x18, #0x800
      mov x6, x18
      add x18, x18, #8
      ldrsw x18, [x18, x10, lsl #2]
      add x18, x18, x6
      br x18
      mov w0, #1
      ret
      mov w0, #2
      ret
out:  ret
''', ro={0x808: rel(T + 0x800, 0x124, 0x12c)}, gap=[(0x120, 'br_x18')]),

dict(name='03j_join_both_bounded', doc='分派块是汇合点（11-04 普查文明6 main 0x10f43e0 / 0x10f3d0c）：直落入边 cmp w10,#2 / b.hi out，另一入边 cmp w10,#2 / b.ls disp 跳进来，'
         '形态同 03h（mov x6,x18 在 ldrsw 前）→ br(0x128) → 0x12c / 0x134 / 0x13c',
     asm='''
      cmp w10, #2
      b.ls disp
      mov w0, #9
      cmp w10, #2
      b.hi out
disp: .inst 0xb0000012
      add x18, x18, #0x800
      mov x6, x18
      ldrsw x18, [x18, x10, lsl #2]
      add x18, x18, x6
      br x18
      mov w0, #1
      ret
      mov w0, #2
      ret
      mov w0, #3
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x12c, 0x134, 0x13c)}, br={0x128: {0x12c, 0x134, 0x13c}}),

dict(name='03k_join_unbounded_edge', doc='反例：同 03j，但另一入边是 cbz w0,disp（不带下标界）→ br(0x128) 报缺口',
     asm='''
      nop
      cbz w0, disp
      mov w0, #9
      cmp w10, #2
      b.hi out
disp: .inst 0xb0000012
      add x18, x18, #0x800
      mov x6, x18
      ldrsw x18, [x18, x10, lsl #2]
      add x18, x18, x6
      br x18
      mov w0, #1
      ret
      mov w0, #2
      ret
      mov w0, #3
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x12c, 0x134, 0x13c)}, gap=[(0x128, 'br_x18')]),

dict(name='03e_base_copy_after_clobber', doc='反例：基址 x10 在拷贝前就被改（ldrsw / mov w10,w0 / mov x12,x10 / add x18,x9,x12）→ x12 里不是表基址，br(0x120) 报缺口',
     asm='''
      cmp w9, #2
      b.hi out
      .inst 0xb000000a
      add x10, x10, #0x800
      ldrsw x9, [x10, x9, lsl #2]
      mov w10, w0
      mov x12, x10
      add x18, x9, x12
      br x18
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x120, 0x120, 0x120)}, gap=[(0x120, 'br_x18')]),

dict(name='03f_base_copy_overwritten', doc='反例：拷贝之后目的寄存器又被改（mov x12,x10 / mov x12,x0 / add x18,x9,x12）→ add 用的不是表基址，br(0x120) 报缺口',
     asm='''
      cmp w9, #2
      b.hi out
      .inst 0xb000000a
      add x10, x10, #0x800
      ldrsw x9, [x10, x9, lsl #2]
      mov x12, x10
      mov x12, x0
      add x18, x9, x12
      br x18
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x124, 0x124, 0x124)}, gap=[(0x120, 'br_x18')]),

dict(name='03b_word_rel_base_x17', doc='字表·相对（经典），表基址在 x17（王国之泪 ② 也用 x17 作表基址）：adrp/add x17 → 0x1800；cmp w18,#2 / b.hi；ldrsw x18,[x17,x18,lsl#2] / add x18,x18,x17 / br(0x118) → 0x11c / 0x124 / 0x12c',
     asm='''
      .inst 0xb0000011
      add x17, x17, #0x800
      cmp w18, #2
      b.hi out
      ldrsw x18, [x17, x18, lsl #2]
      add x18, x18, x17
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x11c, 0x124, 0x12c)}, br={0x118: {0x11c, 0x124, 0x12c}}),
# 03b 现状：classify_br 认成经典 rel，site_br_rel 断言 breg 不在 x16 / x17 / x18 → 只记「br_rel」缺口，不再退回按值分派（br_tab），整个模块退出码 3


dict(name='04_word_rel_other_reg', doc='字表·表项在别的寄存器：adrp/add x13；cmp w9,#2 / b.hi；ldrsw x0,[x13,x9,lsl#2] / add x18,x0,x13 / br(0x118) → 0x11c / 0x124 / 0x12c',
     asm='''
      .inst 0xb000000d
      add x13, x13, #0x800
      cmp w9, #2
      b.hi out
      ldrsw x0, [x13, x9, lsl #2]
      add x18, x0, x13
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x11c, 0x124, 0x12c)}, br={0x118: {0x11c, 0x124, 0x12c}}),

dict(name='05_entry_in_x17', doc='表项读进 x17、add 与 br 之间再改 x17（Blade II main 0x29329c8 形态，#62）：br(0x11c) → 0x120 / 0x128 / 0x130',
     asm='''
      .inst 0xb000000f
      add x15, x15, #0x800
      cmp w17, #2
      b.hi out
      ldrsw x17, [x15, x17, lsl #2]
      add x18, x17, x15
      mov x17, x10
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x120, 0x128, 0x130)}, br={0x11c: {0x120, 0x128, 0x130}}),

dict(name='06_bound_far_other_reg', doc='界检查查 w18、下标 x0（mov w0,w18），检查离 br 超过 16 条（Blade II main 0x2932fec 形态，#62）：br(0x154) → 0x158 / 0x160 / 0x168',
     asm='''
      .inst 0xb000000b
      add x11, x11, #0x800
      mov w0, w18
      cmp w18, #2
      b.hi out
      .rept 14
      add x1, x1, #1
      .endr
      ldrsw x18, [x11, x0, lsl #2]
      add x18, x18, x11
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x158, 0x160, 0x168)}, br={0x154: {0x158, 0x160, 0x168}}),

dict(name='07_index_copied_by_mov', doc='下标经 mov 拷进来：cmp w21,#2 / b.hi / mov w0,w21 / ldrsw x18,[x13,x0,lsl#2] / add x18,x18,x13 / br(0x11c) → 0x120 / 0x128 / 0x130',
     asm='''
      .inst 0xb000000d
      add x13, x13, #0x800
      cmp w21, #2
      b.hi out
      mov w0, w21
      ldrsw x18, [x13, x0, lsl #2]
      add x18, x18, x13
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x120, 0x128, 0x130)}, br={0x11c: {0x120, 0x128, 0x130}}),

dict(name='08_index_masked', doc='掩码下标：and w16,w18,#3 / cmp w16,#2 / b.hi / and x18,x18,#3 / ldrsw x18,[x13,x18,lsl#2] / add / br(0x120) → 0x124 / 0x12c / 0x134',
     asm='''
      .inst 0xb000000d
      add x13, x13, #0x800
      and w16, w18, #3
      cmp w16, #2
      b.hi out
      and x18, x18, #3
      ldrsw x18, [x13, x18, lsl #2]
      add x18, x18, x13
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x124, 0x12c, 0x134)}, br={0x120: {0x124, 0x12c, 0x134}}),

dict(name='09_bhi_after_9_stores', doc='cmp w9,#2 与 b.hi 之间夹 9 条 str，表基址就是 x18（塞尔达 1.6.0 main 0x5a3894 形态，#137）：br(0x13c) → 0x140 / 0x148 / 0x150',
     asm='''
      cmp w9, #2
      .rept 9
      str w5, [x20, #0x10]
      .endr
      b.hi out
      .inst 0xb0000012
      add x18, x18, #0x800
      ldrsw x0, [x18, x9, lsl #2]
      add x18, x0, x18
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x140, 0x148, 0x150)}, br={0x13c: {0x140, 0x148, 0x150}}, known='#137'),

dict(name='10_adr_target_base', doc='adr x18 作目标基址、表基址 x17 在死路径上被改（王国之泪 1.4.3 main 0x5f2a9c 形态）：adr x18,0x124 / ldrsw x0,[x17,x16,lsl#2] / add x18,x18,x0 / br(0x130) → 0x138 / 0x140 / 0x148',
     asm='''
      .inst 0xb0000011
      add x17, x17, #0x800
      cbz w3, dead
      b go
dead: mov w17, w4
      ret
go:   cmp w15, #2
      b.hi out
      mov w16, w15
L:    adr x18, L
      ldrsw x0, [x17, x16, lsl #2]
      add x18, x18, x0
      br x18
      nop
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: ('i32', [0x138 - 0x124, 0x140 - 0x124, 0x148 - 0x124, 0x7ffffff0])}, br={0x130: {0x138, 0x140, 0x148}}),

dict(name='11_far_adr_halfword', doc='远 adr + 半字表：adr x18,0x160 在 br 前 12 条 / ldrh w14,[x13,x12,lsl#1] / add x18,x18,x14,lsl#2 / 9 条 mov / br(0x140)；半字表 0,2,4 → 必含 0x160 / 0x168 / 0x170，至多按半字全铺 0x160 + 4i（i < 65536；王国之泪 1.4.3 main 0x680528 形态）。代码段放大到 0x410000，表在 ro 0x410900（adrp x13 页差 0x410：0x9000208d）', text=0x410000,
     asm='''
      .inst 0x9000208d
      add x13, x13, #0x900
      cmp w12, #2
      b.hi out
      adr x18, B
      ldrh w14, [x13, x12, lsl #1]
      add x18, x18, x14, lsl #2
      mov w0, w4
      mov w1, w4
      mov w2, w4
      mov w3, w4
      mov w5, w4
      mov w6, w4
      mov w7, w4
      mov w8, w4
      mov w9, w4
      br x18
      .rept 7
      nop
      .endr
B:    ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x900: ('u16', [0, 2, 4])}, br={0x140: ({0x160, 0x168, 0x170}, {0x160 + 4 * i for i in range(65536)})}),

dict(name='12_excl_retry_head', doc='外置重试头：窗口 0x100 ldxr / cmp / b.ne / add w18 / 0x110 stxr / cbnz → 0x140；0x140 ldxr / cmp / 0x148 b.eq → 0x110（跳回前面窗口的 stxr；王国之泪 1.4.3 main 0x18598 形态）→ 两段并成一个窗口、0 缺口',
     asm='''
      ldxr w17, [x10]
      cmp w15, w17
      b.ne wfail
      add w18, w15, #1
wst:  stxr w17, w18, [x10]
      cbnz w17, whead
      ret
wfail: ret
.org 0x40
whead: ldxr w17, [x10]
      cmp w15, w17
      b.eq wst
      b wfail
''', stat={'window': 1}),

dict(name='13_table_in_text_adr_base', doc='表在 .text、表基址由 adr 给（adr x13,0x130 / cmp w18,#2 / b.hi / ldrsw x18,[x13,x18,lsl#2] / add x18,x18,x13 / br(0x114)）；FDE 只盖到 0x12c，表在函数外 → 0x118 / 0x120 / 0x128',
     asm='''
      adr x13, tbl
      cmp w18, #2
      b.hi out
      ldrsw x18, [x13, x18, lsl #2]
      add x18, x18, x13
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
tbl:  .word 0x118 - 0x130, 0x120 - 0x130, 0x128 - 0x130, 0
''', fde=0x30, br={0x114: {0x118, 0x120, 0x128}}, known='未见于实测游戏（clang 的跳转表在 .rodata）：留作形态记录，命中时改写器报缺口'),

dict(name='14_tail_call', doc='尾调用：ldr x18,[x0,#8] / br x18(0x104) → 按 K18 槽值跳（br x16），没有静态落点',
     asm='''
      ldr x18, [x0, #8]
      br x18
''', dyn=[0x104]),

dict(name='15_blr_x18', doc='blr x18(0x104)：x16 取 K18 槽值、x30 = 原返回地址 0x108，blr 换 br x16，没有静态落点',
     asm='''
      ldr x18, [x0, #8]
      blr x18
      ret
''', dyn=[0x104]),

dict(name='15b_tail_call_ldp', doc='尾调用（10-26 普查奥日1 IL2CPP 虚调用）：ldp x18, x10, [x10] 一次取 {方法指针, 方法数据}、基址与另一目的同为 x10，中间用 x10，br x18(0x108) → 按 K18 槽值跳',
     asm='''
      ldp x18, x10, [x10]
      mov x1, x10
      br x18
''', dyn=[0x108]),

dict(name='15c_tail_call_ldp_touched', doc='反例：ldp 取 x18 后、br 前又读了 x18（add x1, x18, #1）→ 不是尾调用形态，目标集也认不出，br(0x108) 报缺口',
     asm='''
      ldp x18, x10, [x0, #0x128]
      add x1, x18, #1
      br x18
''', gap=[(0x108, 'br_x18')]),

dict(name='16_jump_into_table_mid', doc='从前面跳进 ldrsw 与 add 之间（cbz w5 → 0x118）：经典形态不认，交按值分派（运行时比对 K18 槽真值，跳入路径算出的值不在集合里就 brk）→ br(0x11c) 落点仍是 0x120 / 0x128 / 0x130',
     asm='''
      .inst 0xb0000011
      add x17, x17, #0x800
      cbz w5, mid
      cmp w18, #2
      b.hi out
      ldrsw x18, [x17, x18, lsl #2]
mid:  add x18, x18, x17
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x120, 0x128, 0x130)}, br={0x11c: {0x120, 0x128, 0x130}}),

dict(name='17_target_outside_function', doc='反例：表的第 3 项指到函数外（数据段 0x2000）→ br(0x118) 拒绝',
     asm='''
      .inst 0xb0000011
      add x17, x17, #0x800
      cmp w18, #2
      b.hi out
      ldrsw x18, [x17, x18, lsl #2]
      add x18, x18, x17
      br x18
      ret
      nop
      ret
      nop
      ret
out:  ret
''', ro={0x800: rel(T + 0x800, 0x11c, 0x124, 0x2000)}, gap=[(0x118, 'br_x18')]),

dict(name='18_excl_window_uses_x18', doc='独占窗口里读 x18：ldxr / add w0,w0,w18 / stxr / cbnz 回 0x100 → 整段搬进补丁区（窗口 1）、0 缺口',
     asm='''
w:    ldxr w0, [x1]
      add w0, w0, w18
      stxr w2, w0, [x1]
      cbnz w2, w
      ret
''', stat={'window': 1}),

dict(name='19_branch_into_window', doc='反例：窗口外的 cbz w5(0x100) 跳进窗口中间 0x108 → 拒绝（window 缺口）',
     asm='''
      cbz w5, mid
w:    ldxr w0, [x1]
mid:  add w0, w0, w18
      stxr w2, w0, [x1]
      cbnz w2, w
      ret
''', gap=[(0x100, 'window')]),
dict(name='33_add_x18_sp_imm_overflow', doc='add x18,sp,#0xffc（哈迪斯 2 的 EOS NRO 0x2d89c0）：立即数加保存区超 12 位，安卓仍不碰 sp 下方，表头 REWRITE_ABI 为 <目标>-sp-safe-v1，不退回 below-sp-v1',
     asm='''
      add x18, sp, #0xffc
      ret
''', abi='sp-safe-v1'),
]
