"""SHA-256 计算器（new() → update / hexdigest）：导入（pack/jobs/core.py）、资源包（pack/pack.py）、资源包核对（pack/verify.py）共用一份。
Windows 走系统 CNG（BCrypt，用 CPU 的 SHA 指令）：11-06 出包速度线天眼实测，玩家机同款 Python 3.12 / OpenSSL 3.0 的 hashlib
只有 0.55 GB/s（没用上 SHA 指令），王国之泪 18 GB 原件导入要 54 秒；CNG 同一份 0.90 GB/s，结果逐位相同。
算法提供程序每个进程只开一次（资源包 30.5 万个小文件逐个开关有开销；同一句柄可跨线程建哈希对象）。别的平台照旧 hashlib（Mac 2.9 GB/s）。"""
import hashlib
import os

_ALG = None


def _bcrypt():
    global _ALG
    if _ALG is None:
        import ctypes as C
        bc = C.WinDLL("bcrypt")
        for f in (bc.BCryptOpenAlgorithmProvider, bc.BCryptCreateHash, bc.BCryptHashData, bc.BCryptFinishHash, bc.BCryptDestroyHash):
            f.restype = C.c_long
        alg = C.c_void_p()
        if bc.BCryptOpenAlgorithmProvider(C.byref(alg), C.c_wchar_p("SHA256"), None, 0):
            raise OSError("BCrypt SHA256 打不开")
        _ALG = (C, bc, alg)
    return _ALG


class _Cng:
    def __init__(self):
        self.C, self.bc, alg = _bcrypt()
        self.h = self.C.c_void_p()
        if self.bc.BCryptCreateHash(alg, self.C.byref(self.h), None, 0, None, 0, 0):
            raise OSError("BCryptCreateHash 失败")

    def update(self, data):
        if self.bc.BCryptHashData(self.h, self.C.c_char_p(bytes(data)), self.C.c_ulong(len(data)), 0):
            raise OSError("BCryptHashData 失败")

    def hexdigest(self):
        out = self.C.create_string_buffer(32)
        try:
            if self.bc.BCryptFinishHash(self.h, out, 32, 0):
                raise OSError("BCryptFinishHash 失败")
        finally:
            self.bc.BCryptDestroyHash(self.h)
        return out.raw.hex()


def new():
    return _Cng() if os.name == "nt" else hashlib.sha256()
