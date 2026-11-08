# 真实签名样本（#1120）

macOS 26.4.1 上用 `codesign` 临时签名（ad hoc，不带证书、不带描述文件、不含任何私密信息）生成的最小 iOS Mach-O，给 `pack/iml_check.py` 纯 Python 读法当「真实签名样本」组用。

生成方法：

```sh
echo 'int main(void){return 0;}' > m.c
xcrun -sdk iphoneos clang -arch arm64 -o m m.c                    # iml_ok_fat 用 -arch arm64 -arch arm64e
cp m iml_ok && codesign -f -s - --entitlements <权限.plist> iml_ok
```

| 文件 | 权限 | 旧读法（codesign，main dbb080e7a）期望 → 实测 |
|---|---|---|
| `iml_ok` | IML | 绿 → 🟢，rc=0 |
| `iml_missing` | 只有 get-task-allow | 红（缺 IML）→ 【红】缺「提高内存上限」，rc=1 |
| `iml_banned` | IML + dynamic-codesigning | 红（禁用键）→ 【红】含私有 JIT 键，rc=1 |
| `iml_ok_fat` | IML，arm64 + arm64e 双架构 | 绿 → 🟢，rc=0 |

签名的 SuperBlob 里，XML 权限（槽 5，魔数 0xfade7171）和 DER 权限（槽 7，魔数 0xfade7172）都有。

## 合成描述文件 CMS

`profile_synthetic.cms` 由 Windows 上 Git 官方随附的 OpenSSL 3.2.4 生成。
仅有 TESTTEAM / SYNTHETIC-DEVICE 等合成标识，无真实团队、设备、账号或开发证书。
自签公钥证书只用于构造 CMS，不代表 Apple 信任；生成私钥不入仓库。
解出的 plist 独立期望写在 `tests/iml_signed_sample_test.py`。

```sh
openssl req -x509 -newkey rsa:2048 -noenc -keyout synthetic-key.pem -out synthetic-cert.pem -days 3650 -subj /CN=S2Arm-Synthetic-Test
openssl cms -sign -binary -nodetach -nosmimecap -md sha256 -in profile.plist -signer synthetic-cert.pem -inkey synthetic-key.pem -outform DER -out profile_synthetic.cms
openssl cms -verify -binary -noverify -inform DER -in profile_synthetic.cms -out verified-profile.plist
```

最后一条仅验证合成 CMS 的签名，不验证证书信任链。生成端原 plist 与解出 plist 的 SHA-256 均为
`c2f56b079754cbf09836f5448c621d6a5847ec11e291f132a1e37f7878d87731`。
测试和门禁不调用 OpenSSL、不联网。

Windows / Linux：`python3 tests/iml_signed_sample_test.py`。
Mac 新旧读取对照：`python3 tests/iml_signed_sample_test.py --mac-parity`；非 Mac 返回 2（未运行）。
同提交真实 ad hoc App / 真实开发描述文件 App 的对照由维护方在 PR Ready 后本地接续，原件不入仓库。
