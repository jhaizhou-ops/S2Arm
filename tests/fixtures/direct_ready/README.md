# H02 合成输入、C 参考实现和口径

全部键为合成值，无游戏、着色器正文或存档数据。入口：

```sh
python3 tools/direct_ready.py --seen <seen_shaders.tsv> --keys <keys.tsv>
bash tests/direct_ready_test.sh
cc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -DDIRECT_READY_MAIN \
  tests/fixtures/direct_ready/reference.c -o <构建目录>/direct_ready_ref
<构建目录>/direct_ready_ref --seen <seen_shaders.tsv> --keys <keys.tsv>
```

按 §12.3 及 PR #157 直连线评审的新契约：有效键仅为 **16 位小写十六进制**。
仅去掉行尾 ASCII 空格、TAB、CR、LF；空行忽略。不隐式转换大小写。
`keys` 中的大写、表头、额外列、BOM 或其他不合法内容报输入错误（退出 2）；
`seen` 中的 `code:<哈希16>`、大写及其他坏行均保留为缺口（退出 1），不会跳过坏行或中止报告。
坏行按去掉行尾空白后的完整字节串去重、排序，不截断。展示时将 TAB、NUL、
非 ASCII 字节和反斜杠写成 `\xHH`，避免破坏输出 TSV；展示转义不参与匹配和排序。
显式指定两份文件，不猜包目录下的链版本。seen 文件不存在表示尚未收集，按空 seen
输出未就绪（退出 1），不会创建文件；keys 不存在、seen/keys 是目录或其他读取错误仍退出 2。
即使 seen 缺失，keys 的内容也必须校验，非法 keys 仍退出 2。输入只读。

覆盖率、`seen/covered/missing` 均按唯一键计算。按认领时确认的口径，
缺口按 **seen 输入行出现次数**降序，同次数按整行原始字节序升序；
去重的生产者文件每键次数都是 1，这不是游戏调用热度，工具不补造真实频次。
空 seen（文件不存在或只有空白行）没有游玩证据，必须返回 `ready=0`、退出 1，覆盖率注明无样本。
即使没有缺口，也必须有非空 seen 才算已覆盖；本工具不表示所有直连条件满足或游戏测试完成。

退出码 0 = 已覆盖，1 = 未就绪（有缺口或空 seen），2 = 参数、keys 内容或文件读取错误；输入错误只写 stderr，
不输出部分成功摘要。第一行固定为 `ready=0|1 seen=N covered=M missing=K`。

`seen.tsv` 共 8 行、4 个唯一键；`keys.tsv` 虽有重复，仅覆盖其中的 `...0001`。
故 covered=1、missing=3、覆盖率 25%。缺口 `...0002` 有 3 行，
`code:0123456789abcdef` 有 2 行，`...0003` 有 1 行；完整期望在 `expected.txt`，手算固定。

`reference.c` 导出 `direct_ready_reference(FILE*, FILE*, DirectReadyResult*, char*, size_t)`：
消费当前文件位置到 EOF，流仍由调用方关闭；输出必须为空结果，使用后调用
`direct_ready_result_free`。未定义 `DIRECT_READY_MAIN` 时不带 CLI main，可供对拍接入。
`seen_input=NULL` 明确表示 seen 文件不存在；其他打开错误由调用方报错，不得当作缺失。
`keys_input` 必须有效，缺失 seen 时也会正常解析校验 keys。
C 实现自行解析、排序和去重，不调用 Python；`missing_rows` 中每个 `key` 是 `length` 字节，
不是 NUL 结尾字符串，字节所有权属于结果。参考函数会分配内存，尚未接入生产运行时。

回归入口编译真实 C 实现，逐例与手算期望和 Python CLI 对拍；临时输入与二进制仅在临时目录。
十万键性能包含进程启动、文件读取和完整输出，分别量全覆盖与全缺口，Python/C 每次均要求小于 1 秒。
