#!/bin/bash
# 服务层单测卡死留现场（services/test.sh，假 dotnet + 假仓库树，约 15 秒）：bash tests/svc_hang_test.sh
# 期望（按规则手写）：上限 S2A_SVC_TEST_S=12、假单测一直不退 → 第 2 秒起抓栈（上限前 10 秒）、到 12 秒被杀退出 124、bin/test.hang.txt 是 sample 的线程栈、输出点名现场文件；
#   假单测 1 秒正常跑完 → 退出 0、不抓栈（没有 test.hang.txt）
# 非苹果系统（11-01 审计 P1-41）：services/test.sh 第一行在非 Darwin 上退出 75，假 dotnet 执行不到、四条全红。调被测拷贝时 PATH 前放一个假 uname（报 Darwin / arm64）桩掉这道苹果闸，
#   只测超时、抓栈、预检循环；抓栈用 /usr/bin/sample（macOS 自带），没有它时只判超时与预检、抓栈那半条不判，其余全过则退出 75（环境未就绪，不当断言失败）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
S=$T/services; mkdir -p $S/systemdata $S/vpx $S/opus $S/tests $S/S2A.Services.Tests $T/tz; cp $H/services/test.sh $H/services/build_output.sh $S/; touch $T/tz/binaryList.txt
for f in vpx/build.sh opus/build.sh systemdata/make_tzdata.sh; do echo 'echo /x/lib.a' > $S/$f; done
cat > $T/dotnet <<'SH'
#!/bin/bash
[ "$1" = build ] && { echo "    0 Error(s)"; exit 0; }
[ "${2:-}" = --list-modes ] && { printf '%s\n' $FAKE_MODES; exit 0; }   # 单测程序自报的独立模式清单（TestDiscovery.Modes），test.sh 按它逐个起进程
case "${2:-}" in
  --*) printf 'preflight %s\n' "$2" >> "$FAKE_TRACE"; [ "${FAKE_PREFLIGHT_FAIL:-}" = "$2" ] && exit 42; exit 0 ;;
esac
printf 'main\n' >> "$FAKE_TRACE"
echo "共 1 项"; [ "${FAKE_HANG:-0}" = 1 ] && exec sleep 600; exit 0
SH
chmod +x $T/dotnet
mkdir -p $T/fakebin; printf '#!/bin/sh\ncase "${1:-}" in -m) echo arm64 ;; *) echo Darwin ;; esac\n' > $T/fakebin/uname; chmod +x $T/fakebin/uname   # 桩苹果闸与架构判断
SVC() { PATH=$T/fakebin:$PATH bash $S/test.sh; }
SAMPLE=1; [ -x /usr/bin/sample ] || SAMPLE=0
# 卡死例的上界只为分开「到上限被杀」与「等假单测自己睡醒」：假单测睡 600 秒、上界 300 秒，两者差几个数量级；原来睡 60、上界 40，
#   上限 12 秒 + sample 抓栈收尾在满负载 mini（11-02 普查并发）上就到 40 秒，无缓存实跑假红
printf '#!/bin/bash\nprintf "provider\\n" >> "$FAKE_TRACE"\n' > $S/tests/t_native_provider.sh
export FAKE_TRACE=$T/trace
export FAKE_MODES="--account-lifetime --audio-lifetime --arp-application --arp-capacity --configuration --legacy-environment --host-configuration --host-startup-retry --exports-startup-retry --exports-zone-race --exports-zone-cleanup-fail --romfs-symlink --screen-aspect --input-lifetime --inflight-close --ipc-allocation --domain-errors --bsd-poll --ldn-room-count --ldn-synthetic-application"   # 假单测程序 --list-modes 报的清单；下面断言逐个都跑到
: > "$FAKE_TRACE"
s0=$SECONDS; o=$(FAKE_HANG=1 DOTNET=$T/dotnet S2A_TZDATA=$T/tz S2A_SVC_TEST_S=12 SVC 2>&1); r=$?; w=$((SECONDS - s0)); HF=$S/S2A.Services.Tests/bin/test.hang.txt
if [ $SAMPLE = 1 ]; then
ck "卡死：退出 ${r}（期望 124）、${w} 秒（期望 ≥ 12 且 < 300：到上限才杀、没等假单测睡满 600 秒）、test.hang.txt 是线程栈（含 Call graph）、输出点名现场" '[ $r = 124 ] && [ $w -ge 12 ] && [ $w -lt 300 ] && grep -q "Call graph" $HF && grep -q "卡死现场（到点前抓的线程栈）：$HF" <<< "$o"'
else
ck "卡死（无 /usr/bin/sample，只判超时）：退出 ${r}（期望 124）、${w} 秒（期望 ≥ 12 且 < 300）" '[ $r = 124 ] && [ $w -ge 12 ] && [ $w -lt 300 ]'
fi
: > "$FAKE_TRACE"
o=$(DOTNET=$T/dotnet S2A_TZDATA=$T/tz S2A_SVC_TEST_S=12 SVC 2>&1); r=$?
ck "正常跑完：退出 ${r}（期望 0）、不抓栈" '[ $r = 0 ] && [ ! -e $HF ]'
all_modes=1
for mode in $FAKE_MODES; do
  grep -Fxq "preflight $mode" "$FAKE_TRACE" || all_modes=0
done
ck "正常运行经过全部预检入口后才执行主测试" '[ "$all_modes" = 1 ] && grep -q "provider" "$FAKE_TRACE" && grep -q "^main$" "$FAKE_TRACE"'
: > "$FAKE_TRACE"
o=$(FAKE_PREFLIGHT_FAIL=--audio-lifetime DOTNET=$T/dotnet S2A_TZDATA=$T/tz S2A_SVC_TEST_S=12 SVC 2>&1); r=$?
ck "预检失败原码传播且不运行主测试" '[ $r = 42 ] && grep -q "服务专项 --audio-lifetime：失败（退出 42）" <<< "$o" && ! grep -q "^main$" "$FAKE_TRACE"'
[ $bad = 0 ] || { . "$(dirname "$0")/keep_scene.sh"; keep_scene svc_hang $T; }; [ $bad = 0 ] || { echo "svc_hang 单测有不通"; exit 1; }
[ $SAMPLE = 1 ] || { echo "svc_hang：超时 / 预检全过；抓栈要 macOS 的 /usr/bin/sample，本机 $(uname -s) 没有，未测（环境未就绪，退出 75）"; exit 75; }
echo "svc_hang 单测全过"
