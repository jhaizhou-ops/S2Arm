# 开源替代共享字体：来源与许可

`pack/fonts/make_open_fonts.py <输出目录>` 生成 7 个 `.bfttf`，与 Switch 系统共享字体同名，替代需要玩家自备的任天堂原版字体。
全部字形来自 SIL Open Font License 1.1（OFL）字体或本项目自绘，可随应用分发。依赖版本钉在 `pack/fonts/requirements.txt`，同输入两次产物逐字节相同。

## 来源（版本钉死，sha256 由生成器下载时校验）

google/fonts 固定提交 `45e3d5269e4a17d823f6d84470bc084dc5ae46f6`，下面写作 `GF/`，即 `https://raw.githubusercontent.com/google/fonts/45e3d5269e4a17d823f6d84470bc084dc5ae46f6/ofl/`。

| 键 | 文件 | 版本 | 许可 | sha256 |
| --- | --- | --- | --- | --- |
| jp | `GF/notosansjp/NotoSansJP[wght].ttf` | 2.004 | OFL 1.1 | `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f` |
| sc | `GF/notosanssc/NotoSansSC[wght].ttf` | 2.004 | OFL 1.1 | `a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da` |
| tc | `GF/notosanstc/NotoSansTC[wght].ttf` | 2.004 | OFL 1.1 | `864727d210d54f2537bbe23b3a839436c3992af72de9322af5270897246bd44f` |
| kr | `GF/notosanskr/NotoSansKR[wght].ttf` | 2.004 | OFL 1.1 | `194018e6b2b293a7964f037b25c0249ce1418bc9ab3c971060a03aa57861e252` |
| latin | `GF/notosans/NotoSans[wdth,wght].ttf` | 2.015 | OFL 1.1 | `bfb7bb691513f12e734dc346c03a03f784912432d7e3fa8e56efcf906fe86b3d` |
| ofl_cjk | `GF/notosanssc/OFL.txt`（四款 CJK 的 OFL.txt 相同） | — | — | `1c05c68c34f9708415aada51f17e1b0092d2cea709bf4a94cd38114f9e73d7d9` |
| ofl_latin | `GF/notosans/OFL.txt` | — | — | `cee9892f9f0cc8fe882c9e9537ee6a89621d86ee7ceaf70b02e2b2b1c25c061a` |
| unihan | `https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip` | Unicode 17.0.0 | Unicode License v3 | `f7a48b2b545acfaa77b2d607ae28747404ce02baefee16396c5d2d7a8ef34b5e` |

Unihan 只用来读两张字表：`kTGH`（通用规范汉字表，8105 字）和 `kIICore`（国际核心汉字集，9810 字），不进产物。
变体字体在 `wght=400`（Latin 另带 `wdth=100`）处定成静态 TrueType（glyf 轮廓）。图标字母用 Noto Sans `wght=700`。

## 产物

| 文件 | 内容 | 字体名 |
| --- | --- | --- |
| `nintendo_udsg-r_std_003.bfttf` | Noto Sans JP：全部非汉字 + JIS X 0213 汉字；另从 Noto Sans 补缺的拉丁扩展、附加符号、希腊、西里尔、标点 | S2Arm Sans JP |
| `nintendo_udsg-r_org_zh-cn_003.bfttf` | Noto Sans SC：GB2312 + 通用规范汉字表 + 国际核心汉字集 + GBK 非汉字 + 常用符号 | S2Arm Sans SC |
| `nintendo_udsg-r_ext_zh-cn_003.bfttf` | Noto Sans SC：拉丁、CJK 部首、表意文字描述符、竖排标点 / 兼容形式；原版的 39 个 GB18030 私用区码位，按 GB18030-2022 映射指到对应标准字的字形 | S2Arm Sans SC Ext |
| `nintendo_udjxh-db_zh-tw_003.bfttf` | Noto Sans TC：Big5 全部（常用 5401 + 次常用 7652 字，共 13063 汉字）+ 常用符号 | S2Arm Sans TC |
| `nintendo_udsg-r_ko_003.bfttf` | Noto Sans KR：KS X 1001 全部（含 4888 个汉字）+ 现代韩文 11172 个音节 + 常用符号 | S2Arm Sans KR |
| `nintendo_ext_003.bfttf` | 手柄按键图标，本项目自绘，码位同原版 | S2Arm Pad Icons |
| `nintendo_ext2_003.bfttf` | 同上，码位范围更大 | S2Arm Pad Icons Ext |

产物目录里还有 `OFL-NotoSansCJK.txt`、`OFL-NotoSans.txt` 两份许可证原文，以及 `MANIFEST.tsv`（逐文件字节数、sha256、码位数）。

## 字表取舍

硬上限：Ryujinx 把除 ext2 以外的 6 个字体解码后，连同各自 8 字节头一起放进 `0x1100000`（17,825,792）字节的共享内存（`Horizon.FontSize`），超了起服务会抛异常。生成器出完会核这笔账，超了就报红退出。

Noto 字形每个汉字平均约 340 字节，原版约 250 字节，按原版字数装不下。如果每款都照对应地区的完整旧国标收：JP 0208、SC 用 GBK、TC 用 Big5、KR 用 KS X 1001 加全部韩文音节，合计约 21 MB。取舍如下（体积是 2026-10-23 的实测）：

- **简中** `org_zh-cn`：只收 GB2312（6763 字）、通用规范汉字表（8105 字，大陆现行标准，人名地名用字都在里面）和国际核心汉字集（9810 字）的并集，共 11828 字，4.44 MB。舍掉的是 GBK 里的繁体和生僻字，以及 CJK 扩展 A。原版这里是 GBK 加扩展 A，有约 1.6 万字我们缺。
- **繁中** `zh-tw`：Big5 全收（覆盖常用繁体），5.11 MB。缺的是原版里 Big5 厂商私用区 367 个码位，Noto 没有这些字形。
- **韩文** `ko`：KS X 1001 全收，包括汉字；现代韩文 11172 个音节全收，4.29 MB。
- **标准** `std`：JIS X 0213（比 0208 多约 1260 字），加欧洲语言要用的拉丁扩展、希腊和西里尔，3.29 MB。
- 中韩字体的非汉字部分，去掉了文本里很少见、体积又大的几块：CJK 兼容方块字 3300–33FF、部首 2E80–2FDF、韩文组合字母、BMP 以外的带圈字母和方块字。各自国标字表里有的照样保留。
- 中韩字体不从 Noto Sans 补拉丁扩展。四款都补每款要多约 0.2 MB，合计会超上限。
- 版式表只留 GSUB 的竖排特性（`vert`、`vrt2`），不带 GPOS。原版也只有 GSUB。

6 个装载字体合计 17,366,676 字节，距上限还剩 459,116 字节。

## 图标字体

两个图标字体的轮廓全部由生成器里的几何代码画出：圆环、圆角矩形、十字键、箭头等，用 skia-pathops 做布尔运算；字母取 Noto Sans 粗体。
码位表照原版 cmap 抄录：ext 为 E000–E1FF、F000、F003–F1FF；ext2 为 E000–E25F、F000–F2C3。每个码位画什么，是看原版渲染出的小图来定的。原版的轮廓数据没有复制进仓库，也没有进产物。
画不出确切含义的码位，统一用中性的圆角方框占位。原版这些码位里有不少本来就是方框占位。

## OFL 要求的声明

- Noto Sans JP / SC / TC / KR：Copyright 2014-2021 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source'.
- Noto Sans：Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic).
- S2Arm Pad Icons / S2Arm Pad Icons Ext：Copyright 2026 The S2Arm Authors. Letterforms derived from Noto Sans, Copyright 2022 The Noto Project Authors.

本项目对上述字体做了子集化、定静态实例、合并字形、改名和自绘，属于 OFL 所说的 Modified Version，按 OFL 1.1 发布：

- 字体名不含保留字体名 “Source”。家族名统一改为 `S2Arm Sans JP/SC/SC Ext/TC/KR`、`S2Arm Pad Icons`、`S2Arm Pad Icons Ext`，名字里不含 “Nintendo”。
- 版权声明保留在每个字体的 name 表里（ID 0），许可说明在 ID 13/14。
- 随应用分发时，许可证原文（产物目录里的 `OFL-*.txt`）要一并带上。字体不单独出售。

OFL 1.1 全文如下，与上游 OFL.txt 相同：

```text
This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://scripts.sil.org/OFL


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```
