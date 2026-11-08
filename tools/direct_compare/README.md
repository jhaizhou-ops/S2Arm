# direct_compare

离线比较两局采集的 PNG，记录身份 / 帧配对、RGB block SSIM、像素差、逐块读数、热图与覆盖。无运行时或覆盖表自动写入。

完整输入、公式、阈值与验收边界见 [研究说明](../../docs/研究/直连画面对比_moongrant.md)。

~~~sh
bash tools/direct_compare/build_png_metrics.sh <构建目录>
python3 tools/direct_compare/direct_compare.py <局A> <局B> --codec <构建目录>/png-metrics --out <新的报告目录> \
  --calibrate <同模式独立校准局A> <同模式独立校准局B>
DIRECT_COMPARE_TEST_ROOT=<测试产物目录> bash tests/direct_compare_test.sh
~~~

需要已有 macOS C 编译器 / 系统框架和 Python ≥3.9 标准库；不安装依赖。退出 0 一致、1 不一致、2 未验证或错误。阈值暂定、真实两款报告待验。生成的真实游戏热图留本地，不入库。


v2 强制独立校准，8×8动态掩码只排除静态SSIM/差异计算；动态面积>50%未验证。缺内容按全屏独立统计，>2%单列「缺内容」。复用用 `--calibration <先前报告目录>/calibration.json`，原来源须保留可读，工具重新核哈希与掩码。输入必须同存档、同系统时间、同路线及采样点；缺校准、坏输入、缺帧或校准无效不能判绿。真实游戏仍待持有者复核。
