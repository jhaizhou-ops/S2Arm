# Metal 编译耗时剖析（R3）

只读测量：一份 MSL 编一次要多久、时间花在哪类结构上。不改编译器、不改出包流程。

| 文件 | 作用 |
| --- | --- |
| `tools/metal_compile_prof.py` | 计时（measure）、按段计时（sections）、二分定位（bisect） |
| `tests/metal_prof/gen_fixtures.py` | 夹具生成器（无随机，同参数重跑逐字节相同） |
| `tests/metal_prof/readings_*.tsv` `*.txt` | 本机实测读数（每批带 load 与 calib_s） |
| `tests/metal_prof/bisect_*.tsv` | 二分结论表（最热函数、边际秒数、轮数） |
| `tests/metal_prof_test.sh` | 单测（纯解析秒级；有 metal 时现生成夹具再跑 measure / sections / bisect 端到端） |

**夹具不入库**（维护方 10-27 要求：4.3 万行生成物不进仓库）。仓库只留生成器与读数，用时现场造：

```bash
python3 tests/metal_prof/gen_fixtures.py --target 1MB      # → build/metal_prof/fixture_1mb.metal（1.04 MiB）
python3 tests/metal_prof/gen_fixtures.py --target 10MB     # → build/metal_prof/fixture_10mb.metal（10.15 MiB）
```

缺省输出目录是仓库的 `build/metal_prof/`（`.gitignore` 里的 `build/`，每棵工作树各一份，不会误入库）；
`--out` 想写哪写哪。下面读数里的两份夹具，都是这两条命令造出来的。

## 四种结构

| 段名 | 结构 | 生成形态 |
| --- | --- | --- |
| `deep_if` | 深嵌套 if 链 | 每函数 24 层 `if` 嵌套，每层带运算与 else 分支 |
| `big_switch` | 超大 switch | 每函数 192 个 case，每 case 两条语句 |
| `huge_body` | 巨型函数体 | 每函数 1200 条直线语句，读 `device const float*`（全常量的直线运算会被 fast-math 常数折叠，实测 1 MB 只剩 3.1 KB AIR，量的就不是这个结构了） |
| `inline` | 大量内联 | 16 个 `[[clang::always_inline]]` 小函数 × 12 个调用点展开 |

每段自带 `#include` 与 kernel 入口（kernel 把本段每个函数都调一遍——死代码的编译耗时没有意义），
所以按 `//#region section <名>` 切出来能单独编译；`sections` 就是靠这个逐段单独测。

## 用法

```bash
python3 tests/metal_prof/gen_fixtures.py --target 1MB      # 先造夹具（不造就没得测）
python3 tools/metal_compile_prof.py measure  build/metal_prof/fixture_1mb.metal --reps 3 --out build/metal_prof/m.tsv
python3 tools/metal_compile_prof.py sections build/metal_prof/fixture_1mb.metal --reps 3 --out build/metal_prof/s.tsv
python3 tools/metal_compile_prof.py bisect   <真实 MSL> --log build/metal_prof/bisect.log --out build/metal_prof/bisect.tsv
```

计时口径：`time.monotonic()` 只包 `xcrun -sdk iphoneos metal -c <源> -o <临时目录>/out.air`；
每个变体先丢 `--warmup` 次（缺省 1）再测 `--reps` 次取中位；产物目录每轮新建、测完删；输入文件只读。

**每轮换源码摘要**：同一份源连编会命中 Metal 自己的编译缓存——实测 2.65 MB 的 deep_if 段
同一份源出现过 1.9 秒，而换一行注释后稳定 7.8–11 秒（差异远超过噪声）。工具因此每轮把源复制到临时目录、
末尾追加一行唯一注释再编，量的是冷编译；`-o` 换路径不管用（缓存键不含输出路径）。

**读数的可比性**：这台机器上同时跑着别的线，`load average` 8–30 之间摆动，同一份 2.65 MB 源在
load≈8 时 7.79 秒、load≈21 时 11.47 秒。所以每次测量都记 `load1`，跨批比较只在同一批内做，
`--calibrate <参照文件>` 会在每个输入前先编一次参照文件记 `calib_s`，用来判断这一批有没有被拖慢。

## 二分怎么定位

1. **函数级**：把候选函数的函数体换成 `{ return {}; }`（签名不动，调用点仍成立），每轮删一半、测一次，
   删掉后更快的那一半更重，继续往它里面切；入口函数（kernel/vertex/fragment）不参与——删它的函数体
   等于把整条调用链一起删掉，差值全归入口，定位不到结构。
2. **收敛后按边际定数**：只留它 vs 连它一起删，两次之差就是它的边际贡献（不受每轮噪声累积影响）。
3. **语句块级**：在最热函数的函数体里按顶层语句切块（if/for/switch 整块算一块），同样二分删一半；
   声明了后面还要用的变量、含 `return` 的块先剔掉（删了编译不过）。其余函数体这层保持已删，
   所以语句块这一层的基线是「其余函数体已删、语句块全留」。
4. 每轮都写进 `--log`（过程日志只在 `build/` 里，不入库）：删了哪一段、剩多少、耗时多少、比基线少多少。

## 实测（2026-10-27，Xcode 27.1 / Apple metal 32023.921，Apple Silicon Mac，load 8–11）

整份夹具（`measure`，reps 3，中位）：

| 夹具（现场生成） | 大小 | 函数数 | 中位秒 | 秒/MiB |
| --- | --- | --- | --- | --- |
| `fixture_1mb.metal` | 1.044 MiB | 1009 | 1.63 | 1.56 |
| `fixture_10mb.metal` | 10.146 MiB | 9678 | 12.60 | 1.24 |

按结构分段（`sections`，每段自带 kernel，逐段单独编译）：

| 结构 | 1 MB 夹具里的段（0.26 MiB） | 秒/MiB | 10 MB 夹具里的段（2.55 MiB） | 秒/MiB |
| --- | --- | --- | --- | --- |
| `deep_if`（深嵌套 if 链） | 0.28 秒 | **1.12** | 7.79 秒 | **3.09** |
| `big_switch`（超大 switch） | 0.41 秒 | 1.54 | 3.39 秒 | 1.35 |
| `huge_body`（巨型函数体） | 0.45 秒 | 1.71 | 3.93 秒 | 1.56 |
| `inline`（大量内联） | 0.93 秒 | **3.54** | 7.42 秒 | **2.86** |

读法：

- **1 MB 量级：大量内联最拖**（3.54 秒/MiB，是深嵌套 if 的 3.2 倍），但体量上去后收敛（2.76）。
- **深嵌套 if 链是唯一随体量超线性的结构**：0.26 MiB 段 1.12 → 2.55 MiB 段 3.09 → 4 MiB 单文件 5.90
  → 10 MiB 单文件 11.25 秒/MiB（10.09 MiB 单文件实测 119.1 秒）。switch 与巨型函数体两档在
  1.3–1.7 秒/MiB 基本不动。
- **无差异的两项**：`big_switch` 与 `huge_body` 在两个量级都落在 1.3–1.7 秒/MiB，差值 0.04–0.16 秒，
  在噪声（同一文件重复测量可差 10–20%）之内，**不算显著**。

单结构放大（各一份独立文件，1 次冷编译；同一时间窗；生成命令 `--structure X --target 4MB`）：

| 结构 | 文件大小 | 秒 | 秒/MiB |
| --- | --- | --- | --- |
| `deep_if` | 4.03 MiB | 24.94 | **5.90** |
| `big_switch` | 4.02 MiB | 5.51 | 1.31 |
| `huge_body` | 4.01 MiB | 5.34 | 1.27 |
| `inline` | 4.15 MiB | 12.00 | 2.76 |
| `deep_if` | 10.09 MiB | 119.10 | **11.25** |

每 MiB 成本的体量曲线（同批同机器状态）：

- `deep_if`：0.25 MiB 1.12 → 2.55 MiB 3.09 → 4.03 MiB 5.90 → 10.09 MiB 11.25 秒/MiB —— **随体量线性上涨**
- `inline`：3.54 → 2.86 → 2.76；`big_switch`：1.54 → 1.35 → 1.31；`huge_body`：1.71 → 1.56 → 1.27 —— **不随体量涨**

## 二分结论（过程日志不入库，结论在这里与 `bisect_*.tsv`）

两次二分都**没有占主导的单个函数**——合成夹具的代价按结构摊在成百上千个函数上（这是夹具性质，不是工具缺陷）：

| 输入 | 函数数 | 基线 | 最热函数边际 | 最热语句块边际 | 编译调用 |
| --- | --- | --- | --- | --- | --- |
| 1 MB 夹具（四段合并） | 1009（候选 1005） | 1.67 秒 | `bigbody_2` 0.04 秒 | 0.02 秒 | 96 次 |
| 10 MB 夹具的 `deep_if` 段 | 551（候选 550） | 7.99 秒 | `ifchain_217` 0.03 秒 | 0.01 秒 | 48 次 |

要复跑同样的二分（日志这次落在 `build/metal_prof/`，不入库）：

```bash
python3 tests/metal_prof/gen_fixtures.py --target 1MB
python3 tools/metal_compile_prof.py bisect build/metal_prof/fixture_1mb.metal --reps 1 \
  --log build/metal_prof/bisect_1mb.log --out build/metal_prof/bisect_1mb.tsv
```

## 测试

`bash tests/metal_prof_test.sh`：纯解析部分秒级；有 metal 时**现场生成**一份 128 KB 夹具
（`python3 tests/metal_prof/gen_fixtures.py --target 128KB --out <mktemp 目录>/fixture.metal`）再跑
measure / sections / bisect 端到端，测完删掉临时目录——测试不依赖任何入库夹具。

耗时（本机 Xcode 27.1，端到端要几十次编译）：`load` 低时约 **15–16 秒**，机器被别的线压满（load 20–30）时到过 **78 秒**。
夹具是现生成的，所以结果可复现的前提是生成器逐字节可复现——单测里有这一条（同参数生成两次比 sha256）。

## 限制

- 夹具是合成的：每函数形态一致、kernel 把本段所有函数都调一遍。真实 MSL 的函数体长短不一、调用链更深，
  绝对秒数不能外推到出包里的某一份着色器；能外推的是「哪类结构在什么体量上开始变贵」。
- 这台机器不是独占的（`load average` 8–30），同一文件不同批次可差 2–6 倍。表里的数取自 load 8–11 的一批，
  跨批比较请用同批数据或 `--calibrate`。
- **10 MB 量级只实测了 `deep_if` 一类**（4 MiB 时另外三类已稳定在 1.27–2.76 秒/MiB，补 10 MB 的增量信息低，
  不做外推）。要补：`--structure big_switch --target 10MB` 后 `measure`，一类约 30–60 秒，四类 3–5 分钟。
- `bisect` 一次几十到上百次编译：1 MB 夹具 96 次约 2 分钟；2.65 MB 段 48 次约 5 分钟。
  真实大文件请先 `sections`/`measure` 缩到出问题的那一段，再二分，或调小 `--reps`。
- 计时只测前端 + 优化到 AIR（`metal -c`），不含 metallib 打包与运行期管线创建；
  出包里的 63 分钟冷编译还包含别的环节，本工具只能回答「编译这一段要多久」。
- 二分在「结构均匀」的合成夹具上定位不到单点（如实记录）；真游戏 MSL 上能不能定位到单个热点函数，
  需要游戏文件，本机没有，**未验**。
