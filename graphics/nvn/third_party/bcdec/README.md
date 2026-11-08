来源：https://github.com/iOrange/bcdec 提交 80859ed（版本 0.985）；经 MacNativeGames（https://github.com/ly05010419/MacNativeGames，MIT，提交 84eebcd0985c）带入。许可见 LICENSE（MIT 或公有领域二选一）。
用途：不支持 BC 压缩格式的显卡（A15 / A16 等）上，直连层把 BC 贴图在 CPU 上解压（graphics/nvn/gfx/tex/nvn_bcdec.c）。

S2ARM LOCAL（#1199，10-31）：`bcdec__bc4_block` / `bcdec__bc4_block_float` 的 `(char)` 改
`(signed char)`——裸 char 在 ARM64/Android 是无符号（AAPCS），BC4/BC5 SNORM 端点比较
错走 e0<=e1 表；x86/Darwin char 有符号不受影响。
