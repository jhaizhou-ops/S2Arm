"""宿主日志「红」行判定（执行器 / 健康表 / 记分板 / 里程碑共用，bash 侧 dev_run.sh 用同一正则 RED_EMPTY_SUMMARY）。
不计红的行：
  ① 「【红】未实现服务：」后面为空——服务层退出时必打的汇总行，列表为空 = 0 个未实现服务（services/S2A.Services/Red.cs 注释：M0 判据是这行为空；10-20 总指挥裁定）
  ② 「【红】出图未满屏」——只进画面格，各调用方按需另算（这里由 skip_fullscreen 决定）"""
import re

RED_EMPTY_SUMMARY = re.compile(r'【红】未实现服务：\s*$')


def is_red(line, skip_fullscreen=True):
    if '【红】' not in line or RED_EMPTY_SUMMARY.search(line): return False
    return not (skip_fullscreen and '出图未满屏' in line)


def red_lines(text, skip_fullscreen=True):
    return [l for l in text.split('\n') if is_red(l, skip_fullscreen)]
