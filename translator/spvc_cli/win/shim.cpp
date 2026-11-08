// spirv-cross 命令行进程内入口的 Windows 版（#1100 W6，11-04 Windows 出包线）：接口与 ../shim.cpp 逐个相同（spvc_cli_run / spvc_cli_run_mem / spvc_cli_free），
//   ../shim.h 照旧预包含进 main.cpp。Windows 的 C 运行库没有 fmemopen / open_memstream，这里改用本线程独占的临时文件（关闭即删，11-05 起见下）：
//   "mem:in" = 把调用方给的 SPIR-V 写进临时文件再按原模式打开；"mem:out" = 打开一个临时文件让命令行写、跑完读回内存；stderr = tmpfile()，跑完倒回读出。
//   只换输入输出的搬运方式，命令行与 SPIRV-Cross 代码一字不动，MSL 输出与 Mac 逐字节同（tests/spvc_win_test.sh 跨机核）。
//   放在子目录：spvc_inproc.identity() 只扫 spvc_cli/ 顶层文件，Windows 胶水不进输出身份（同「不含编译器版本」的道理：MSL 只由 SPIRV-Cross 源码与参数定）。
#define _CRT_SECURE_NO_WARNINGS   // MSVC 运行库把 fopen / tmpfile 标「不安全」弃用；标准 C 用法
#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <cstring>
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#define SPVC_API extern "C" __declspec(dllexport)
int spvc_cli_main(int argc, char *argv[]);
static thread_local FILE *t_err = nullptr;
static thread_local const void *t_in = nullptr; static thread_local size_t t_in_n = 0;
static thread_local HANDLE t_out = INVALID_HANDLE_VALUE;   // mem:out 那份文件的第二个句柄：命令行 fclose 后靠它读回，CloseHandle 时系统删文件
static thread_local char t_path[MAX_PATH];                // 最近一次建的临时文件名（只用于报错）
static volatile LONG g_seq;

// 新建一个只属于本次调用的临时文件 → 句柄（失败 INVALID_HANDLE_VALUE）。11-05 天眼鬼灭之刃 14 支缺键里 9 支「mem:in 建临时文件 失败（GetLastError 5）」：
//   原先用 GetTempFileNameA(dir, "spv", 0)，同一前缀只有 65535 个名字（4 位十六进制），作业被杀留下的 spv*.tmp 在天眼临时目录堆了 15147 个、1 GB；
//   几十个线程同时建删时撞上「删除中」的同名文件，它回 ERROR_ACCESS_DENIED 且不换名重试。现在：名字 = 进程号_线程号_进程内序号（不复用），
//   CREATE_NEW 撞名就换下一个号重试；FILE_FLAG_DELETE_ON_CLOSE：最后一个句柄关掉（含进程被杀）系统就删，不再留垃圾
static HANDLE tmp_open(void)
{
	char dir[MAX_PATH]; DWORD n = GetTempPathA(MAX_PATH, dir); if (!n || n >= MAX_PATH) { t_path[0] = 0; return INVALID_HANDLE_VALUE; }
	for (int i = 0; i < 64; i++) {
		snprintf(t_path, sizeof t_path, "%ss2a_spvc_%lu_%lu_%ld.tmp", dir, (unsigned long)GetCurrentProcessId(), (unsigned long)GetCurrentThreadId(), (long)InterlockedIncrement(&g_seq));
		HANDLE h = CreateFileA(t_path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, CREATE_NEW,
		                       FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
		if (h != INVALID_HANDLE_VALUE) return h;
		DWORD e = GetLastError(); if (e != ERROR_FILE_EXISTS && e != ERROR_ALREADY_EXISTS && e != ERROR_ACCESS_DENIED && e != ERROR_SHARING_VIOLATION) return h;
	}
	return INVALID_HANDLE_VALUE;
}
static FILE *as_file(HANDLE h, const char *mode)   // 句柄 → FILE*（之后 fclose 关句柄）；失败关句柄回 nullptr
{
	int fd = _open_osfhandle((intptr_t)h, _O_BINARY | (mode[0] == 'r' && !strchr(mode, '+') ? _O_RDONLY : 0)); if (fd < 0) { CloseHandle(h); return nullptr; }
	FILE *f = _fdopen(fd, mode); if (!f) _close(fd); return f;
}
static char *slurp(FILE *f, size_t *n)   // 从头读完整个流 → malloc 的缓冲（末尾补 0，长度不含它）
{
	*n = 0; if (!f || fseek(f, 0, SEEK_END)) return nullptr;
	long len = ftell(f); if (len < 0 || fseek(f, 0, SEEK_SET)) return nullptr;
	char *b = (char *)malloc((size_t)len + 1); if (!b) return nullptr;
	*n = fread(b, 1, (size_t)len, f); b[*n] = 0; return b;
}
static char *slurp_h(HANDLE h, size_t *n)   // 同上，直接读句柄（mem:out 的第二个句柄）
{
	*n = 0; LARGE_INTEGER sz, z = {}; if (!GetFileSizeEx(h, &sz) || !SetFilePointerEx(h, z, NULL, FILE_BEGIN)) return nullptr;
	char *b = (char *)malloc((size_t)sz.QuadPart + 1); if (!b) return nullptr;
	DWORD got = 0; size_t k = 0;
	while (k < (size_t)sz.QuadPart && ReadFile(h, b + k, (DWORD)((size_t)sz.QuadPart - k > 0x40000000 ? 0x40000000 : (size_t)sz.QuadPart - k), &got, NULL) && got) k += got;
	if (k != (size_t)sz.QuadPart) { free(b); return nullptr; }
	b[k] = 0; *n = k; return b;
}
// 搬运失败时把哪一步、系统错误码写进本次调用的 stderr（调用方记进 direct_fail「错误」列）：11-05 天眼勇者斗恶龙 XI S 同输入两次各丢 1 / 6 支
//   「Failed to open SPIR-V file: mem:in」，原先只回 nullptr，看不出是建临时文件、写入还是重开失败
static FILE *why(const char *step)
{
	DWORD w = GetLastError(); int e = errno;
	FILE *f = t_err ? t_err : stderr;
	fprintf(f, "[spvc 垫片] %s 失败：%s（GetLastError %lu，errno %d）\n", step, t_path[0] ? t_path : "（无名）", (unsigned long)w, e);
	return nullptr;
}
extern "C" FILE *spvc_shim_fopen(const char *path, const char *mode)
{
	if (path && t_in && !strcmp(path, "mem:in")) {
		HANDLE h = tmp_open(); if (h == INVALID_HANDLE_VALUE) return why("mem:in 建临时文件");
		const char *p = (const char *)t_in; size_t k = 0; DWORD put = 0;
		while (k < t_in_n && WriteFile(h, p + k, (DWORD)(t_in_n - k > 0x40000000 ? 0x40000000 : t_in_n - k), &put, NULL) && put) k += put;
		LARGE_INTEGER z = {};
		if (k != t_in_n || !SetFilePointerEx(h, z, NULL, FILE_BEGIN)) { FILE *r = why("mem:in 写入"); CloseHandle(h); return r; }
		FILE *r = as_file(h, "rb"); return r ? r : why("mem:in 重开");
	}
	if (path && !strcmp(path, "mem:out")) {
		if (t_out != INVALID_HANDLE_VALUE) { CloseHandle(t_out); t_out = INVALID_HANDLE_VALUE; }
		HANDLE h = tmp_open(); if (h == INVALID_HANDLE_VALUE) return why("mem:out 建临时文件");
		if (!DuplicateHandle(GetCurrentProcess(), h, GetCurrentProcess(), &t_out, 0, FALSE, DUPLICATE_SAME_ACCESS)) { t_out = INVALID_HANDLE_VALUE; FILE *r = why("mem:out 复制句柄"); CloseHandle(h); return r; }
		FILE *o = as_file(h, "wb");   // main.cpp 按 "w" 开：Windows 文本模式会把 \n 写成 \r\n，这里一律二进制，同 Mac 字节
		return o ? o : why("mem:out 写开");
	}
	return ::fopen(path, mode && !strcmp(mode, "w") ? "wb" : mode);   // 落盘输出（--output 给真路径）同样按二进制写
}
extern "C" FILE *spvc_shim_err(void) { return t_err ? t_err : stderr; }
SPVC_API int spvc_cli_run(int argc, char **argv, char **err, size_t *len)
{
	HANDLE eh = tmp_open(); FILE *f = eh != INVALID_HANDLE_VALUE ? as_file(eh, "w+b") : nullptr;   // 本次 stderr：同样关闭即删
	t_err = f;
	int rc;
	try { rc = spvc_cli_main(argc, argv); }
	catch (...) { rc = EXIT_FAILURE; }
	t_err = nullptr;
	*err = nullptr; *len = 0;
	if (f) { fflush(f); *err = slurp(f, len); fclose(f); }
	return rc;
}
SPVC_API void spvc_cli_free(char *p) { free(p); }
SPVC_API int spvc_cli_run_mem(int argc, char **argv, const void *in, size_t in_n, char **out, size_t *out_n, char **err, size_t *err_n)
{
	t_in = in; t_in_n = in_n; t_out = INVALID_HANDLE_VALUE; t_path[0] = 0;
	int rc = spvc_cli_run(argc, argv, err, err_n);
	*out = nullptr; *out_n = 0;
	if (t_out != INVALID_HANDLE_VALUE) {   // 命令行写完已自己 fclose；没打开过 mem:out（如参数错早退）就没有输出，同 Mac 版
		*out = slurp_h(t_out, out_n); if (!*out && rc == 0) rc = EXIT_FAILURE;   // 读不回输出 = 这次失败
		CloseHandle(t_out); t_out = INVALID_HANDLE_VALUE;   // 最后一个句柄：系统删文件
	}
	t_in = nullptr; t_in_n = 0; t_path[0] = 0;
	return rc;
}
