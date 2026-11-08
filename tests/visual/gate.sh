#!/bin/bash
# 门禁层：合入后
# 门禁路由：tests/visual/ graphics/tools/shbake/xc_key.sh graphics/metal/ graphics/loop/ graphics/widen/ graphics/track/ graphics/third_party/ graphics/build.mk compat/tree/src/Ryujinx.Graphics. compat/patches/
# 门禁本机：* 10-21 08:0x 首次整步派 mini：同提交 c8fbaad 本机 rc=0（出图 5/5、对拍 5/5、真值 2/2），mini 出图 4/5、对拍 0/2、真值 0/2（train/gate/red_1021075154.log vs run/s2arm/gfxsh/batch/visual_c8f.log）；含旧登记的马车8 竞技场对拍差 24%、动森第 30 帧 7964 像素
# 画幅线门禁钩子（tools/gate.sh 在仓库根以 bash 调用；退出 0 = 绿；最后一行「期望 → 真结果」）。
# 按改动只跑相关项（10-24 jhz 整改「不需要的测试、门禁一律砍掉」；实测整跑 352 秒：单测 20、C 接口 65、编渲染器 54、编回放器 7、② 34、③ 148、④ 21）。
#   GATE_CHANGED 为空（不知道改了啥）= 全跑。各项防什么、什么时候跑：
#   ① 宽屏单测（核心语义：命中 / 写回 / 直连出数 = 通用 GPU 缓冲）+ C 接口（直连调用的结构布局、零分配）：改 graphics/widen/ 或这两个测试目录才跑。
#   ③ 宽屏门禁（九款金样：放宽后中间区逐像素、出图参数、两侧来历）：改 graphics/widen/ 或 tests/visual/widen_gate* 才跑。
#   ④ 逐绘制对拍（动森一段录像逐渲染通道对参照渲染器：防渲染器 / GAL 翻译画错；10-25 录像库误删后只重录这段，暗黑3 / 马车8 两段只带已知差异、回归由 graphics/gate.sh 九款金样逐帧覆盖，摘掉）+ 回放器自检：改 graphics/metal/ compat/ tests/visual/galplay/ drawdiff / diff_list 才跑——改渲染器缺省只剩这一项，约 85 秒。
#   ② 参考录像出图 / 双后端 5 帧 / 真值 2 帧：与 ③④ 重叠，只在改它自己的量具（widen_cmp.py / truth_cmp.py）时跑。
# ①（原）graphics/widen 单测（tests/visual/widen_unit，失败项数即退出码）。
# ②（原）参考录像回放出图——同一份 libnxgal 出基线（16:9）
#    与加宽图（--widen 2.1727），tests/visual/widen_cmp.py 判「中间区 PSNR ≥30 dB、两侧有画面」，并要求回放错误 0、宽屏红计数（序章补内容除外）0；
#    基线回放同时进参照渲染器（Ryujinx Vulkan 后端 @ MoltenVK，--ref）逐帧对拍：差异像素（通道差 >2）≤0.5%；
#    录像在 Windows 真值检查点录的（list.tsv 第 3 列 <游戏>/<检查点>）：基线与加宽图中间 16:9 都要过 tests/visual/truth_cmp.py。
# ③ 同触发条件：宽屏门禁 tests/visual/widen_gate.sh（九款 GAL 金样录像：中间区逐像素对登记值 + 噪声、出图参数变化次数、回放无错），在 ② 之后串行跑（10-21 与 ② 并行时、负载 100 下马车8 基线 --ref 回放超时 200 秒一次，串行免争抢）、共用本钩子编的回放器。
# ④ 同一条件下（③ 之后串行）：双后端逐绘制对拍（画面·着色器线，tests/visual/galplay/DrawDiff.cs）——清单 tests/visual/diff_list.tsv（随代码走列车）每行一段录像：
#    galplay --ref --diff <帧段> --diff-split 每个渲染通道结束两边读回全部颜色目标与深度逐像素比（重同步：每处分歧只算在引入它的通道上；
#    --diff-split 我方每次绘制后结束渲染通道（galplay 用 Barrier 拆；10-21 帧率能耗线起「无存储写的屏障不拆遍」，故回放带 NXGAL_BARRIER_SPLIT=1 恢复屏障拆遍）——长通道里镜像写的回放不确定（问题清单 #1，NXGAL_NO_MIRROR=1 同样消失）不让门禁随机红，那个缺陷由 drawdiff.py 两遍定性单独盯），
#    tests/visual/drawdiff.py --gate 判：参照回放异常 0、二进制程序 0、回放错误 0、比对次数 = 清单（射程）、分歧全在清单「已知」列里（新分歧红；已知的修好了照报，删清单行）。
#    不过的段同条件再回放一遍：第二遍也不过才红；第二遍过 = 不复现，记黄、不判红，两遍目录都留。依据（10-22 本机 4 路并行负载，同一回放器两段各 40 遍）：
#    暗黑3 记录 5501 参照侧哈希 40 遍变 3 遍（我方 40 遍恒定；MoltenVK 上的 Ryujinx Vulkan，我方改不到），马车8 记录 7726 我方侧 40 遍变 1 遍（3 像素 / 2.99 级）。
#    按像素 / 级数设容差会连真实小回归一起放过（暗黑3 已知分歧本身就是 15 像素）；代码改动造成的分歧每遍都复现，重跑照样红（正对照 --break-shader 同理）。
#    计数口径：越界 / 循环到上限计数缺省关（两端同出货口径）；本钩子全是比像素，进来时 NXGAL_BOUNDS_COUNT=1 直接红（计数开时片元含设备原子写，运行时不执行也算，
#    苹果 GPU 上「丢弃后隐式导数」的绘制结果会变——10-21 实测马车8 帧 3-4 新分歧 3、暗黑3 帧 1-3 新 4，只去掉原子写即回 0，docs/坑记录.md）。
#    录像在内容寻址库 ${S2A_DIFF_RECS:-~/.s2arm/gate_data/diffrec}（tests/visual/diff_store.sh 入库，只增不改），清单只按文件名引用。
#    库放在 run/ 之外（10-25 清盘时 run/s2arm/diff* 通配把整个库删了、三段录像只能重录）：safe_rm.sh 只删 run/s2arm 等允许根，gc 只删自己建的目录，都碰不到这里
# 产物全在私有临时目录（libnxgal 用 OUT= 编到私有目录，不碰 build/gal，免得和其他钩子并行时互相覆盖）；每次回放墙钟上限 120 秒。
# 参考录像：${S2A_VISUAL_RECS:-~/.s2arm/run/s2arm/visual/recs}/list.tsv（列：录像文件、帧号逗号分隔、真值检查点或 -、说明）；录像与真值不进仓库。
# 子项键（tools/gate.sh 分派 mini 用，见本文件头「# 门禁本机：」）：ref/<录像文件> = 该录像的双后端对拍（基线回放 --ref）；widen/<款> = 宽屏门禁里这一款。
#   GATE_SKIP="<键…>"：ref 键的录像基线回放不带 --ref、不判双后端，widen 键的款宽屏门禁不跑（别处另跑），末行写明；
#   GATE_ONLY="<键…>"：只编回放器，只跑这些键（ref 键：基线 --ref 回放 + 判双后端；widen 键：宽屏门禁只跑这几款），不跑单测 / 宽屏出图 / 真值。
#   键不是 ref/ widen/ 开头、录像不在 list.tsv、款不在 tests/visual/widen_gate.tsv = 红。
set -u
[ "${NXGAL_BOUNDS_COUNT:-}" = 1 ] && { echo "画幅线 / 画面·着色器线：计数关（出货口径）下比像素 → 计数开着（NXGAL_BOUNDS_COUNT=1），本钩子全是比像素，红"; exit 1; }
R=$(pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RECS=${S2A_VISUAL_RECS:-$HOME/.s2arm/run/s2arm/visual/recs}
red=0; msg=(); ONLY=${GATE_ONLY:-}; SKIPK=${GATE_SKIP:-}; refskip=
for k in $SKIPK $ONLY; do
  case $k in
    ref/?*) [ ! -f "$RECS/list.tsv" ] || cut -f1 "$RECS/list.tsv" | grep -qxF "${k#ref/}" || { echo "画幅线：子项键 $k 的录像不在 $RECS/list.tsv → 红"; exit 1; };;
    widen/?*) cut -f1 tests/visual/widen_gate.tsv | grep -qxF "${k#widen/}" || { echo "画幅线：子项键 $k 的款不在 tests/visual/widen_gate.tsv → 红"; exit 1; };;
    *) echo "画幅线：子项键 $k 认不得（只认 ref/<录像>、widen/<款>）→ 红"; exit 1;;
  esac
done
WO=; WS=; for k in $ONLY; do case $k in widen/*) WO="$WO ${k#widen/}";; esac; done; for k in $SKIPK; do case $k in widen/*) WS="$WS ${k#widen/}";; esac; done

# 各子项耗时（10-21 总指挥：09:46 那批本步平时 178 秒、负载下超 600 秒，要看清是哪一项膨胀）：末行带「耗时 …」
TM=(); tm() { TM+=("$1 $(( SECONDS - $2 ))s"); }
# 按改动定跑哪几项（见文件头）；GATE_CHANGED 为空 = 全跑
if [ -n "${GATE_CHANGED:-}" ]; then
  RU=0; RW=0; RG=0; RL=0
  for f in $GATE_CHANGED; do case $f in
    graphics/widen/*|tests/visual/widen_unit/*|tests/visual/widen_capi/*) RU=1; RW=1;;
    tests/visual/widen_gate*|tests/visual/widen_lib_key*|graphics/tools/shbake/xc_key.sh|graphics/metal/tools/gal_offline.py) RW=1;;   # 离线库键脚本 / 键单测 / 离线编译器也算（11-01 审计 P1-40：只改它们时键单测没人跑）
    graphics/metal/*|graphics/loop/*|graphics/track/*|graphics/third_party/*|graphics/build.mk|compat/tree/src/Ryujinx.Graphics.*|compat/patches/*|tests/visual/galplay/*|tests/visual/drawdiff.py|tests/visual/diff_list.tsv) RG=1;;   # 回放器真正编进去的面（测试出包线 10-24 收窄）
    tests/visual/widen_cmp.py|tests/visual/truth_cmp.py|tests/visual/gate.sh) RL=1;;
  esac; done
else RU=1; RW=1; RG=1; RL=1; fi
if [ -z "$ONLY" ] && [ $RU = 1 ]; then
s0=$SECONDS
out=$(timeout 300 dotnet run -c Release --artifacts-path "$T/art" --project tests/visual/widen_unit 2>&1); rc=$?
tot=$(echo "$out" | grep -o '共 [0-9]* 项，失败 [0-9]* 项' | tail -1)
[ $rc = 0 ] || { red=1; echo "$out" | grep '【红】' | head -10; }
msg+=("单测 ${tot:-未跑完（rc=${rc}）}"); tm 单测 $s0
# 宽屏核心 C 接口（直连回放层调，graphics/widen/export/s2a_widen.h）：NativeAOT 发布版上对拍结构布局与稳态零分配
s0=$SECONDS
out=$(bash tests/visual/widen_capi/run.sh "$T/capi" 2>&1); rc=$?
tot=$(echo "$out" | grep -o '共 [0-9]* 项，失败 [0-9]* 项' | tail -1)
[ $rc = 0 ] || { red=1; echo "$out" | grep -E '【红】|失败' | head -10; }
msg+=("C 接口 ${tot:-未跑完（rc=${rc}）}"); tm C接口 $s0
elif [ -n "$ONLY" ]; then msg+=("单测另跑（本次只跑 ${ONLY}）"); else msg+=("单测 / C 接口跳过（没改 graphics/widen/）"); fi

# 离线库缓存键单测（11-01 审计 P1-40）：自带源码副本、不要参考录像，排在编渲染器与参考录像之前——清单缺 / 编译失败时也照跑
#   键该变不变 → 宽屏门禁拿旧库对拍；不该变却变 → 整库重建约 900 秒、钩子超时
if { [ -z "$ONLY" ] && [ $RW = 1 ]; } || [ -n "$WO" ]; then
  s0=$SECONDS; bash tests/visual/widen_lib_key_test.sh > "$T/widen_lib_key.log" 2>&1 || red=1; tm 宽屏离线库键 $s0
  grep -E '^不通' "$T/widen_lib_key.log"; msg+=("宽屏离线库缓存键：$(tail -1 "$T/widen_lib_key.log")")
fi
need=0; [ $RW = 1 ] || [ $RG = 1 ] || [ $RL = 1 ] || [ -n "$ONLY" ] && need=1
if [ $need = 1 ]; then
  if [ ! -f "$RECS/list.tsv" ]; then
    red=1; msg+=("参考录像缺：$RECS/list.tsv")
  elif s0=$SECONDS; ! make -C graphics/metal OUT="$T/gal" "$T/gal/libnxgal.dylib" "$T/gal/gal_xc" "$T/gal/t_vraw/vs.spv" "$T/gal/t_vraw/fs.spv" -j"${S2A_CPU_GATE:-8}" > "$T/make.log" 2>&1; then
    red=1; tail -5 "$T/make.log"; msg+=("libnxgal 编译失败")
  elif tm 编渲染器 $s0; s0=$SECONDS; ! timeout 400 dotnet build -c Release --artifacts-path "$T/art" -p:OutDir="$T/play/" tests/visual/galplay > "$T/build.log" 2>&1; then
    red=1; grep -E ' error ' "$T/build.log" | sort -u | head -5; msg+=("galplay 编译失败")
  else
    tm 编回放器 $s0; cp "$T/gal/libnxgal.dylib" "$T/play/"
    # 参照端吃原始位顶点输入（画面·着色器线 10-21，galplay/RefRawVertex.cs）：按格式改回类型声明后参照端逐位对、不改写时画错（反证）
    s0=$SECONDS; vr=$(timeout 120 "$T/play/galplay" --selftest-vraw "$T/gal/t_vraw" 2>&1); vrc=$?; tm 参照原始位 $s0
    if [ $vrc != 0 ]; then red=1; echo "$vr" | grep -E '✗' | head -8; fi
    msg+=("$(echo "$vr" | grep '参照端原始位顶点输入单测' | tail -1 | sed 's/^参照端原始位顶点输入单测：//')（参照原始位，rc=${vrc}）")
    # 参照端 D24S8 深度上传 / 读回往返（画幅线 10-23，galplay/RefD24Test.cs、Ryujinx 0166）：逐对拍比 D24 深度、重同步写回都靠它
    s0=$SECONDS; dz=$(timeout 120 "$T/play/galplay" --selftest-ref-d24 2>&1); dzc=$?; tm 参照D24 $s0
    if [ $dzc != 0 ]; then red=1; echo "$dz" | grep -E '✗' | head -3; fi
    msg+=("$(echo "$dz" | grep '参照 D24S8 往返' | tail -1 | sed 's/^[✓✗] //')（rc=${dzc}）")
    pass=0; all=0
    tpass=0; tall=0; rpass=0; rall=0
    if [ $RL = 1 ] || [ -n "$ONLY" ]; then
    while IFS=$'\t' read -r rec frames truth note; do
      [ -n "$rec" ] || continue
      if [ -n "$ONLY" ]; then case " $ONLY " in *" ref/$rec "*) ;; *) continue;; esac; fi
      ref=--ref; case " $SKIPK " in *" ref/$rec "*) ref=; refskip="$refskip $rec";; esac
      base=$T/out/${rec%.rec}_base; wide=$T/out/${rec%.rec}_wide
      s0=$SECONDS; timeout 200 "$T/play/galplay" "$RECS/$rec" "$base" $ref --frames "$frames" > "$T/${rec}_b.log" 2>&1; rb=$?; tm "${rec%.rec}基线" $s0; s0=$SECONDS
      rw=0; [ -z "$ONLY" ] && { timeout 120 "$T/play/galplay" "$RECS/$rec" "$wide" --widen 2.1727 --frames "$frames" > "$T/${rec}_w.log" 2>&1; rw=$?; tm "${rec%.rec}加宽" $s0; }
      for fr in ${frames//,/ }; do
        if [ -z "$ONLY" ]; then all=$((all + 1)); else rall=$((rall + 1)); fi
        if [ $rb != 0 ] || [ $rw != 0 ]; then
          red=1; echo "🔴 $rec 帧 ${fr}：回放退出码 基线 $rb / 加宽 $rw"; grep -E '回放错误|游戏行为红计数' "$T/${rec}_w.log" 2> /dev/null | head -3
          continue
        fi
        if [ -z "$ONLY" ]; then
          if line=$(python3 tests/visual/widen_cmp.py "$base/present_$fr.png" "$wide/present_$fr.png" 2>&1); then pass=$((pass + 1)); echo "🟢 $rec 帧 ${fr}：$line"
          else red=1; echo "🔴 $rec 帧 ${fr}：$line"; fi
        fi
        if [ -n "$ref" ]; then
        rl=$(grep -E "^帧 ${fr}：差异像素" "$T/${rec}_b.log" | head -1); [ -z "$ONLY" ] && rall=$((rall + 1))
        if [ -n "$rl" ] && python3 -c "import sys,re; v=float(re.search(r'差异像素 ([0-9.]+)%', sys.argv[1]).group(1)); sys.exit(0 if v <= 0.5 else 1)" "$rl"; then rpass=$((rpass + 1)); echo "🟢 $rec 帧 $fr 双后端：$rl"
        else red=1; echo "🔴 $rec 帧 $fr 双后端：${rl:-没有对拍行}"; fi
        fi
        if [ -z "$ONLY" ] && [ "${truth:--}" != - ]; then
          for side in base wide; do
            tall=$((tall + 1)); img=$T/out/${rec%.rec}_$side/present_$fr.png
            if out=$(python3 tests/visual/truth_cmp.py ${truth%/*} ${truth#*/} "$img" $([ $side = wide ] && echo --center16x9) 2>&1); then tpass=$((tpass + 1)); echo "🟢 $rec 帧 $fr $side 对 Windows 真值 ${truth}：$(echo "$out" | grep -E '每格 SSIM 最低' | head -1)"
            else red=1; echo "🔴 $rec 帧 $fr $side 对 Windows 真值 ${truth}："; echo "$out" | grep -E '^\|' | head -9; fi
          done
        fi
      done
    done < "$RECS/list.tsv"
    # 清单在但一条都没跑（空清单 / 只有空行）= 这段没验证，记红（11-01 审计 P2-50：原先计数从 0 起、空循环不记红）
    if [ -z "$ONLY" ] && [ $all = 0 ]; then red=1; echo "🔴 参考录像清单 $RECS/list.tsv 在但一条录像都没跑"; msg+=("参考录像清单在但 0 条跑过")
    elif [ -n "$ONLY" ] && case " $ONLY " in *" ref/"*) true;; *) false;; esac && [ $rall = 0 ]; then red=1; echo "🔴 指定的 ref/ 键一帧都没跑（${ONLY}）"; msg+=("指定 ref/ 键 0 帧跑过"); fi
    if [ -n "$ONLY" ]; then [ $rall -gt 0 ] && msg+=("双后端对拍 $rpass/$rall 帧过（只跑 ${ONLY}）")
    else msg+=("宽屏出图 $pass/$all 帧过" "双后端对拍 $rpass/$rall 帧过${refskip:+（${refskip# } 另跑）}" "Windows 真值 $tpass/$tall 过"); fi
    else msg+=("参考录像出图 / 双后端 / 真值跳过（没改它的量具）"); fi
    if { [ -z "$ONLY" ] && [ $RW = 1 ]; } || [ -n "$WO" ]; then
    s0=$SECONDS; WIDEN_GATE_ONLY=${WO# } WIDEN_GATE_SKIP=${WS# } bash tests/visual/widen_gate.sh "$T/play" "$T/gal" > "$T/widen_gate.log" 2>&1 || red=1; tm 宽屏门禁 $s0
    grep -E '^🔴|^    \||^墙钟' "$T/widen_gate.log"
    msg+=("$(tail -1 "$T/widen_gate.log" | sed 's/^宽屏门禁：期望.*→ 真结果 /宽屏门禁 /')")
    fi
    [ -z "$ONLY" ] && [ $RW = 0 ] && msg+=("宽屏门禁跳过（没改 graphics/widen/）")
    # ④ 逐绘制对拍：只在整跑时跑（GATE_ONLY 分派子项时不跑，本项没有子项键）
    if [ -z "$ONLY" ] && [ $RG = 1 ]; then
      DR=${S2A_DIFF_RECS:-$HOME/.s2arm/gate_data/diffrec}; dpass=0; dall=0; dcmp=0; mkdir -p "$T/diff"; d0=$SECONDS
      while IFS=$'\t' read -r rec fr ncmp known note; do
        case $rec in ''|'#'*|录像) continue;; esac
        dall=$((dall + 1)); o=$T/diff/${rec%.rec}
        if [ ! -f "$DR/$rec" ]; then red=1; echo "🔴 逐绘制对拍录像缺：$DR/${rec}（${note}）"; continue; fi
        NXGAL_BARRIER_SPLIT=1 timeout 240 "$T/play/galplay" "$DR/$rec" "$o" --ref --diff "$fr" --diff-split --until $(( ${fr#*-} + 1 )) > "$o.log" 2>&1; pr1=$?
        # 回放器非 0（含超时 124）先记红，不进比对、不重跑（11-01 审计 P2-49：原先不看退出码，超时 / 崩溃后比对过了也算过）
        # 回放器退出码：0 = 无分歧、4 = 比对有分歧（--diff 的正常结果，交 drawdiff --gate 按已知差异判）；1 回放出错、6 抓帧红、124 超时、其余崩溃才直接记红
        #   （11-01：P2-49 首版「非 0 即红」把正常的 4 也判红，合入后层 acnh 逐绘制对拍误红）
        if [ $pr1 != 0 ] && [ $pr1 != 4 ]; then red=1; echo "🔴 逐绘制对拍 $rec 帧 ${fr}：回放器退出码 ${pr1}$([ $pr1 = 124 ] && echo '（超 240 秒）')：$(tail -2 "$o.log" | tr '\n' ' ' | cut -c1-200)"
        elif line=$(python3 tests/visual/drawdiff.py --gate "$o" --known "$known" --compares "$ncmp" 2>&1); then dpass=$((dpass + 1)); echo "🟢 逐绘制对拍 $rec 帧 ${fr}：$(echo "$line" | tail -1)"
        else
          # 第一遍不过：同条件再回放一遍（见文件头 ④：回放有不确定，复现才算）；重跑过关要两遍回放器都正常结束
          line2=; NXGAL_BARRIER_SPLIT=1 timeout 240 "$T/play/galplay" "$DR/$rec" "$o.r2" --ref --diff "$fr" --diff-split --until $(( ${fr#*-} + 1 )) > "$o.r2.log" 2>&1; pr2=$?
          if { [ $pr2 = 0 ] || [ $pr2 = 4 ]; } && line2=$(python3 tests/visual/drawdiff.py --gate "$o.r2" --known "$known" --compares "$ncmp" 2>&1); then dpass=$((dpass + 1))
            echo "🟡 逐绘制对拍 $rec 帧 ${fr}：第一遍不过、重跑不复现（回放不确定，不判红；两遍在 ${o}、$o.r2）：$(echo "$line" | tail -1)"; echo "$line" | grep '新分歧' | head -3
          else red=1; echo "🔴 逐绘制对拍 $rec 帧 ${fr}（${note}；两遍都不过，第二遍回放器退出码 ${pr2}）："; echo "${line2:-}" | tail -8; grep -E '回放错误|第一处分歧' "$o.r2.log" | head -3; [ -s "$o.r2/report.txt" ] || echo "   回放没写出报告（超 240 秒或崩溃）：$(tail -2 "$o.r2.log" | tr '\n' ' ')"; fi
        fi
        dcmp=$((dcmp + ncmp))
      done < tests/visual/diff_list.tsv
      # 正对照（尺子不瞎）：清单第 1 段（动森帐篷，0 已知分歧）只改坏我方一支着色器（对拍段里画到颜色目标最多的程序，全部 OpFMul→OpFAdd），必须报出新分歧
      pc=$(awk -F'\t' 'NR == 2 { print $1 "\t" $2 "\t" $3 "\t" $4 }' tests/visual/diff_list.tsv); pok=未跑
      if [ -n "$pc" ]; then IFS=$'\t' read -r rec fr ncmp known <<< "$pc"; o=$T/diff/break
        if [ -f "$DR/$rec" ]; then NXGAL_BARRIER_SPLIT=1 timeout 150 "$T/play/galplay" "$DR/$rec" "$o" --ref --diff "$fr" --diff-split --break-shader --until $(( ${fr#*-} + 1 )) > "$o.log" 2>&1
          python3 tests/visual/drawdiff.py --gate "$o" --known "$known" > "$o.cls" 2>&1
          if grep -q '、新 [1-9]' "$o.cls"; then pok="报出$(grep -o '、新 [0-9]*' "$o.cls" | head -1 | tr -d '、') 处"
          else red=1; pok=没报出（尺子瞎或回放失败）; echo "🔴 逐绘制对拍正对照：改坏着色器后没有新分歧"; tail -3 "$o.cls"; tail -3 "$o.log"; fi; fi; fi
      msg+=("逐绘制对拍 $dpass/$dall 段过（比对 $dcmp 次；正对照 ${pok}；$((SECONDS - d0)) 秒）")
    elif [ -z "$ONLY" ]; then msg+=("逐绘制对拍跳过（没改 graphics/metal/ compat/ 与回放器）")
    fi
  fi
else
  msg+=("出图跳过（没改 graphics/widen/ graphics/metal/ compat/ 与回放量具）")
fi
[ ${#TM[@]} -gt 0 ] && { echo "耗时：${TM[*]}"; msg+=("耗时 ${TM[*]}"); }
j=""; for m in "${msg[@]}"; do j="${j:+${j}；}$m"; done
echo "画幅线 / 画面·着色器线：单测全过、宽屏出图 / 对拍 / 真值 / 逐绘制对拍全过 → $j$([ $red = 0 ] && echo '，绿' || echo '，红')"
exit $red
