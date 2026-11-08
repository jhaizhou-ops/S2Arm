// spirv-cross 命令行的进程内入口（见 shim.h）：spvc_cli_run(argc, argv, &err, &len) → 返回码，err 为本次调用写到 stderr 的全部文本（malloc，spvc_cli_free 释放）
//   spvc_cli_run_mem：同上，输入是内存里的 SPIR-V（命令行里写 "mem:in"）、输出交回内存（写 "mem:out"），不经文件
#include <cstdio>
#include <cstdlib>
#include <cstring>
int spvc_cli_main(int argc, char *argv[]);
static thread_local FILE *t_err = nullptr;
static thread_local const void *t_in = nullptr; static thread_local size_t t_in_n = 0;
static thread_local char *t_out = nullptr; static thread_local size_t t_out_n = 0;
extern "C" FILE *spvc_shim_fopen(const char *path, const char *mode)
{
	if (path && t_in && !strcmp(path, "mem:in")) return fmemopen(const_cast<void *>(t_in), t_in_n, mode);
	if (path && !strcmp(path, "mem:out")) { free(t_out); t_out = nullptr; t_out_n = 0; return open_memstream(&t_out, &t_out_n); }
	return ::fopen(path, mode);
}
extern "C" FILE *spvc_shim_err(void) { return t_err ? t_err : stderr; }
extern "C" int spvc_cli_run(int argc, char **argv, char **err, size_t *len)
{
	char *buf = nullptr; size_t n = 0;
	FILE *f = open_memstream(&buf, &n);
	t_err = f;
	int rc;
	try { rc = spvc_cli_main(argc, argv); }
	catch (...) { rc = EXIT_FAILURE; }
	t_err = nullptr;
	if (f) fclose(f);
	*err = buf; *len = n;
	return rc;
}
extern "C" void spvc_cli_free(char *p) { free(p); }
extern "C" int spvc_cli_run_mem(int argc, char **argv, const void *in, size_t in_n, char **out, size_t *out_n, char **err, size_t *err_n)
{
	t_in = in; t_in_n = in_n; free(t_out); t_out = nullptr; t_out_n = 0;
	int rc = spvc_cli_run(argc, argv, err, err_n);
	*out = t_out; *out_n = t_out_n; t_out = nullptr; t_out_n = 0; t_in = nullptr; t_in_n = 0;   // 交给调用方（spvc_cli_free 释放）
	return rc;
}
