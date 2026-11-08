// ZBIC 解码与 NSO 规整单测（11-04 自写解码器 pack/nx_unpack/ZbicDecoder.cs 替换 ezhevita.ZstdSharp.Zbic）。不用游戏文件、不要密钥。
// 测试帧：kinnay zbic 1.0.1（GPL，只当黑盒、只在测试机的临时环境里跑，不进仓库）压缩下面 Gen() 造的确定性合成文本得到，十六进制原样贴在这里；
//   期望值 = Gen() 的输出本身（不经被测解码器算出）。三帧各有一个压缩块，走查过：字面量 Huffman 的权重是 FSE 压缩（BIC 表头），
//   三张序列表都是 FSE_Compressed（BIC 表头）——即 ZBIC 与标准 zstd 唯一不同的那段读法每帧要过 4 次。
//   另有一帧带「低概率」标志（FLP，见下）。
//   校验和帧：zstd 1.5.7 命令行（-19 --check）压的一行文本，只用原样字面量和预定义序列表（没有 FSE 表头，两种格式相同），魔数换成 ZBIC；zbic 黑盒解得出同一行。
using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

int pass = 0, fail = 0;
void Ck(string what, bool ok) { if (ok) { pass++; Console.WriteLine("通 " + what); } else { fail++; Console.WriteLine("不通 " + what); } }
string Err(Func<byte[]> f) { try { f(); return null; } catch (InvalidDataException e) { return e.Message; } }
bool Throws(Func<byte[]> f, string want) { var m = Err(f); if (m != null) Console.WriteLine("   报错：" + m); return m != null && m.Contains(want); }

string[] W = { "the","of","and","to","in","is","was","for","on","that","with","as","by","at","from","this","be","or","are","an","which","it","not","have","had" };
byte[] Gen(int seed, int n) {   // 线性同余选词：x = x*1103515245 + 12345 (mod 2^31)，r = x >> 16；r%7==0 补 r%1000 的十进制，r%13==0 换行否则空格
    long x = seed; var o = new StringBuilder();
    while (o.Length < n) {
        x = (x * 1103515245 + 12345) & 0x7fffffff; long r = x >> 16;
        o.Append(W[r % W.Length]); if (r % 7 == 0) o.Append(r % 1000); o.Append(r % 13 == 0 ? '\n' : ' ');
    }
    return Encoding.ASCII.GetBytes(o.ToString()).Take(n).ToArray();
}
byte[] H(string s) => Convert.FromHexString(s);
string F1 =
    "5a42494360b80a7d270086aa6b1905647acf4005e05fd2650f362db1a7ffd0e13625372f7e55f1630064006400dc4c66c3f3eb7a3526e4bdef592545" +
    "355854ba6725c044aff71e4552ed2ce95fa4e1cffcd735d672066fbeb606f361e07a2166e32300163170fe2add492c5280b3e114e353c4df33f1c7fc" +
    "0426aef1112445bae641fc1a38a1f906bfb688bfe76bbfe78bc1e620cb9c2c629e9a11b571632c68f063bed021fe37b82e6a3e250213a3f1006b5f52" +
    "4651337863d56cbe824c9a7c6f954839ac4808ed97c6a7d2279a6725b05a844b2d67cde0a3ad000df16bdde04360828d00c960826c6c9cf97339aa88" +
    "1faaa603aa120a4c3b434d95c6d9f2deab48e87352681eed878119fc828014ff7ba34870846e1ffe01dab6304fe30154da0762cb454370f8223d0fe6" +
    "43313ee83ff820a92b30cfa944b1d14b4d0a8c96cb1ed6ddd1bc4525b51039c1ae5d150ec22219848d0f0702f7ded77cb946b134999a790e121ab740" +
    "cc56906148b5bd8740943057b345f2a245d10739e7bd51a276f03027a8453ad6ca38c56414fdba82742881638466957e772ca3f96b9c3c453a62b648" +
    "6409f36bbd2655b1390854113f84f63f25990fc53a8a0281afa80971d6ff4bf0a14ba7c0087ef966024376151c07f94db222a831085b81ca707dd28f" +
    "fb1e85990f0ced60bfa90c0737c1e1a596a4ab6b69027dd570187d65bbc1ce64efdb4889c274945b3d56e024cf57be4cc60938462415cae6908be3e4" +
    "4a88f7a7d4618a0321da10efaf9d085c3d5961ea81d532bad9ce3bb70e0da0d41d687167603d2bba08358c3238af79ba802604cd11f1d31e455e3c4d" +
    "0757a4326e20cf5bef12640f9ca063c5161e06430aad454aaf407904dbb060f26765c977a7ef61cd1a1e3ecd6ad570679932082af8a058ac6b3ef184" +
    "346e9ae5ae83af1513e32fbf6b4734df59f43d960c383703331502381f76905dac5bba33a8c9e70e3d4b5e5a322270a6fbcccd17e7c4851bf6a55354" +
    "c5e55ccbc9d5d31d00c29b3a0ddea2a0a26f887845720ac6d3e3c4e6145305d80440c1418314562c73ae5fbcfb9524c174667cc395d10e1c385499cd" +
    "67c24c161b99296617496664e35638a83094cdce26f05ae4cc39a2cde64220e12fdc95c89b460ffffd0765a643ae199c91da471064d49724aa3ab765" +
    "d7eaba9076ab212be030e1441fa93585311a420d2bc90948fde33e7a01ebda2ccc376f1bb05940b8922a5eb090dfdd4ef4da7f54609d3df3f30d0508" +
    "f199f367ab29c46dc5743ee7e8d029c2ee0598d337bcc8a50921a3dd5e10c4ae71debc70c2539a980cd3905eac795d3f3c5981d22324af0c223fa71f" +
    "fa5100414c6b9926fa9fc48aaded49b5a2115c2b8bd182febefc636e3ca79e630302076ae53956df9290bb5d0454102b8e0c1ad8db4600995b4a9594" +
    "f7d4c792c8a571c619d1a747c2c2a6400570507e33b0c4812476d4e324ba0b74b38b60aa37e145a24c6ff1ef3412d404ce164d141fc4547009c274e9" +
    "78da337c9ee4137c848eff95b457350dee3e5af6561a510fe3304ba3215856422a9ed7913687851a9ccd09609abb2e43865f98b2a1693fe6d197bf74" +
    "e8c45407761b3d61511ae378d503c662ae5bfbc99a50cdfd8934570c9a1ab7c51366b9c9aa441d4091bac031d48bcf40f6c16c8c016eaa41f274e70b" +
    "017c7657f4c962deaa553bcf02c56ecab703d60f7365bab5d8d66e07696be6dfea881a760a4123378a4ac4a5b4f498664d3c062b28b67eefb7c39eb1" +
    "7283bbef81eaa0c4fb0700b12a";
string F2 =
    "5a42494360dc040d1500c65a461905647acf4005c04bd265974696d8d37f74b9a58d9cae5f751e3d0040003f0028dbd9a322d48efe469ba7517a9742" +
    "f63ca063147cb5457fecc55ff6e81673e453e217db8b63743b60d08b8ed9a3e0c802980d78143d25e04dc0e6d81ea87929e9443b1a356e5353738185" +
    "706b8ee0c15202f78a6350f3a79e6a638caadb7651d00048e91820f9974c8bfd1a4044d7c032019bb179b00cdffb09fe2b348b82a36156dbe64b3db5" +
    "9421448f5bf15492d41c9fc57b6fea3312d2ab83fce253061d578e59ec5392e6dfa1c5ed9000c8af703b60f3f641c85278d0538109cda2d99da1cdcf" +
    "4941af482a3c19edc52e8390ec35449f9f3ac98290d38b63a44307f9276a46eed691bf6824c7bf438c333e9d93265f6b4e4a695eec3f80caa809ff1a" +
    "3fe80283476f4007f8293c91954303056656409f03ba2b19452162b44b4f6542c1d9a7fe6970473718b86d97893a2ad6389cc8ab337e2ca277039a36" +
    "4008bd090a55b27fc0bc51ba7efc599e9b69629dd98001221532884723894c12ea61017c448ea55ed8408fb0887dacc24df5a271662062db03c760ee" +
    "a3ec0f15c7886050158d1ce179c916124ffc39808e7eb1b073267863db7fb813b4e6127d5ede7ec739d3905149c772b16d19931e450667e3814a81f0" +
    "631c41a46772086871287cf892fcf8c6d93236490ceaf79db2c5bf551ce0e384d101c81d0987943031857c524c8274ae78d3f91e8319921b496e1e06" +
    "025966392a27d38363cc1b616faccdf4b1e84f4a1345af252d38b20489879c2c19fe78f0b97705ea6117b80421ec6b3fbb19758293f0b3cc367b6bea" +
    "a048b398fc5c81184c4ca458f5b6bc80199a61dc84740864729df31182a442cec064a77638e8ada66528679c5717f305dfeb6854b89c3fe88b8c926f" +
    "f0d677d8d77638d07bf4b84f09ce4ed4c4f32baca01d15";
string F3 =
    "5a424943605801b5090002cf281b056512357310005166f67156a4fd584226147e69a50d2e8a7a210b6fcc1e8d3f20ee78b59520d3f8e960045aa635" +
    "2e8fe66dde5516c02f455605a5d0596795c5a747910273e070dcbe3a567f84b5fa7290e333a463d05bc7c3c17dee0b053d6c8c04f2f4380ca4b1f105" +
    "e68f516648fab0583ccb7e4a8c78e367abe00f054f004dc103d8b5c537663ffdf2f219e1f8cce16001ccb7be94d4bc1f107f9a7dc7edcd1b46a809e7" +
    "45f9e1f4b450c019066862d9d1260a06674a45a49a0104dea08779252712882a4318e4aed37d004d3452656e663aa766c6fe95ca914dccafdb106064" +
    "168888aeede2c9dcf932a0631a713a772b603dda87c5932fabcf02c07f945fdcb1bdaf3b3f9e9ad53966e9c324eb0a8a1ee757adb18493ac7e063459" +
    "a6d303c8dd4ff3119b3d5562588be7db760b3555";
// 低概率帧：同一 zbic 黑盒按级别 1 压 Gen(36, 14500)（5477 字节，base64）；三张序列表的 BIC 表头都带「低概率」标志（首字节最高位 = 1），上面三帧都不带
string FLP =
    "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";
string FCK = "28b52ffd244aa50100a402533241726d205a42494320636865636b73756d20746573743a2061626320303132333435363738392e0a02002e86cfcf3901d0076ca4";   // 前 4 字节是标准 zstd 魔数，用时换成 ZBIC
var frames = new[] { H(F1), H(F2), H(F3) }; var plain = new[] { Gen(1, 3000), Gen(2, 1500), Gen(3, 600) };

// ---- 解码器 ----
for (int i = 0; i < 3; i++) {
    byte[] got = null; var m = Err(() => got = ZbicDecoder.Decompress(frames[i], plain[i].Length));
    Ck($"A{i + 1} BIC 帧 {frames[i].Length} 字节 → {plain[i].Length} 字节，与合成原文逐字节相同{(m != null ? "（报错：" + m + "）" : "")}", got != null && got.AsSpan().SequenceEqual(plain[i]));
}
var lpf = Convert.FromBase64String(FLP); var lpPlain = Gen(36, 14500); byte[] lpGot = null; var lpErr = Err(() => lpGot = ZbicDecoder.Decompress(lpf, lpPlain.Length));
Ck($"A5 低概率标志的 BIC 帧 {lpf.Length} 字节 → {lpPlain.Length} 字节，与合成原文逐字节相同{(lpErr != null ? "（报错：" + lpErr + "）" : "")}", lpGot != null && lpGot.AsSpan().SequenceEqual(lpPlain));
var all = frames.SelectMany(f => f).ToArray(); var allPlain = plain.SelectMany(p => p).ToArray();
Ck("A4 三帧首尾相接一次解出 = 三段原文相接", Err(() => ZbicDecoder.Decompress(all, allPlain.Length)) == null && ZbicDecoder.Decompress(all, allPlain.Length).AsSpan().SequenceEqual(allPlain));
var ckf = H(FCK); "ZBIC"u8.CopyTo(ckf); var ckText = Encoding.ASCII.GetBytes("S2Arm ZBIC checksum test: abcabcabcabcabcabcabcabc 0123456789 0123456789.\n");
Ck("B1 带校验和的帧解出原文（XXH64 低 32 位对上）", Err(() => ZbicDecoder.Decompress(ckf, ckText.Length)) == null && ZbicDecoder.Decompress(ckf, ckText.Length).AsSpan().SequenceEqual(ckText));
Ck("B2 XXH64 公开向量：\"\" = ef46db3751d8e999、\"abc\" = 44bc2cf5ad770999", ZbicDecoder.XxHash64(Array.Empty<byte>()) == 0xef46db3751d8e999UL && ZbicDecoder.XxHash64("abc"u8) == 0x44bc2cf5ad770999UL);
var ckBad = (byte[])ckf.Clone(); ckBad[^1] ^= 1;
Ck("B3 负对照：校验和改一位 → 报错", Throws(() => ZbicDecoder.Decompress(ckBad, ckText.Length), "校验和不符"));
Ck("C1 负对照：标准 zstd 帧（魔数 28 B5 2F FD）→ 报红「不是 ZBIC」", Throws(() => ZbicDecoder.Decompress(H(FCK), ckText.Length), "标准 zstd"));
var odd = (byte[])frames[0].Clone(); "ABCD"u8.CopyTo(odd);
Ck("C2 负对照：不认识的帧魔数 → 报红", Throws(() => ZbicDecoder.Decompress(odd, plain[0].Length), "不认识的帧魔数"));
Ck("C3 负对照：空数据 → 报红", Throws(() => ZbicDecoder.Decompress(Array.Empty<byte>(), 0), "没有 ZBIC 帧"));
int cutBad = 0; for (int c = 1; c < frames[0].Length; c++) if (Err(() => ZbicDecoder.Decompress(frames[0][..c], plain[0].Length)) == null) cutBad++;
Ck($"C4 负对照：A1 帧截断到 1…{frames[0].Length - 1} 字节，每种都报错（没报的 {cutBad} 种）", cutBad == 0);
Ck("C5 负对照：期望长度不符 → 报错", Throws(() => ZbicDecoder.Decompress(frames[0], plain[0].Length + 1), "期望"));
// 逐字节改坏：每个位置异或 0x01。帧不带校验和，格式本身有余量：zbic 黑盒对同样的 1273 处改动，有 3 处（15、20、459）仍解出原文——
//   15 是 Huffman 权重 BIC 表头载荷最后被读入的字节、20 / 459 是倒序比特流里读过头才碰到的位，都不影响结果。期望：我方「仍解出原文」的恰好是这 3 处，
//   其余要么报错、要么解出的不等于原文（不同的那些靠 NSO 的段 SHA-256 兜，见 N8）
int decErr = 0; var same = new System.Collections.Generic.List<int>();
for (int k = 0; k < frames[0].Length; k++) {
    var b = (byte[])frames[0].Clone(); b[k] ^= 1; byte[] o = null;
    if (Err(() => o = ZbicDecoder.Decompress(b, plain[0].Length)) != null) decErr++; else if (o.AsSpan().SequenceEqual(plain[0])) same.Add(k);
}
Console.WriteLine($"   A1 帧逐字节改坏 {frames[0].Length} 处：解码器自己报错 {decErr} 处（zbic 黑盒 480），解出与原文不同 {frames[0].Length - decErr - same.Count} 处，仍等于原文 {same.Count} 处（{string.Join("、", same)}）");
Ck("D1 改坏后仍解出原文的位置 = zbic 黑盒的 15、20、459", same.SequenceEqual(new[] { 15, 20, 459 }));

// ---- NSO 规整（NsoZbic.Normalize） ----
var modname = Encoding.ASCII.GetBytes("main\0\0\0\0");
byte[] Make(uint flags, Func<int, byte[]> body) {
    using var ms = new MemoryStream(); var h = new byte[0x100]; "NSO0"u8.CopyTo(h);
    BitConverter.TryWriteBytes(new Span<byte>(h, 0x0C, 4), flags);
    BitConverter.TryWriteBytes(new Span<byte>(h, 0x1C, 4), 0x100u); BitConverter.TryWriteBytes(new Span<byte>(h, 0x2C, 4), (uint)modname.Length);
    int at = 0x100 + modname.Length; var bodies = new byte[3][]; uint mem = 0;
    for (int i = 0; i < 3; i++) {
        bodies[i] = body(i); int o = new[] { 0x10, 0x20, 0x30 }[i];
        BitConverter.TryWriteBytes(new Span<byte>(h, o, 4), (uint)at); BitConverter.TryWriteBytes(new Span<byte>(h, o + 4, 4), mem); BitConverter.TryWriteBytes(new Span<byte>(h, o + 8, 4), (uint)plain[i].Length);
        BitConverter.TryWriteBytes(new Span<byte>(h, 0x60 + 4 * i, 4), (uint)bodies[i].Length); SHA256.HashData(plain[i]).CopyTo(h, 0xA0 + 0x20 * i);
        at += bodies[i].Length; mem += (uint)plain[i].Length;
    }
    ms.Write(h); ms.Write(modname); foreach (var b in bodies) ms.Write(b); return ms.ToArray();
}
byte[] SegOf(byte[] n, int i) { int off = BitConverter.ToInt32(n, new[] { 0x10, 0x20, 0x30 }[i]), fsz = BitConverter.ToInt32(n, 0x60 + 4 * i); return n[off..(off + fsz)]; }
bool SegsOk(byte[] n) => Enumerable.Range(0, 3).All(i => SegOf(n, i).AsSpan().SequenceEqual(plain[i]));

// --emit <样本.nso> [期望.nso] [标志(16 进制，缺省 BF)]：把上面那份合成 ZBIC NSO 落盘（与 N 组同一份 frames/plain），
//   给了第二个参数就把 NsoZbic.Normalize 的期望产物也写出来——给 pack/ns2_dump.py 与 --nso-normalize 子命令的端到端用例造真样本。
if (args.Length >= 2 && args[0] == "--emit") {
    var em = Make(args.Length > 3 ? Convert.ToUInt32(args[3], 16) : 0xBFu, i => frames[i]);
    File.WriteAllBytes(args[1], em);
    if (args.Length > 2) File.WriteAllBytes(args[2], NsoZbic.Normalize(em, Path.GetFileName(args[1])));
    return 0;
}

var z = Make(0xBF, i => frames[i]); var n = NsoZbic.Normalize(z, "main");
Ck("N1 ZBIC 0xBF（火纹 main 的值）：三段解出与原文逐字节相同", SegsOk(n));
Ck($"N1 标志 0xBF → 0x38（压缩位与 ZBIC 清掉、哈希位保留；实得 0x{BitConverter.ToUInt32(n, 0x0C):x}）", BitConverter.ToUInt32(n, 0x0C) == 0x38);
Ck("N1 模块名保留、文件 = 头 + 名 + 三段原长", n.AsSpan(0x100, modname.Length).SequenceEqual(modname) && n.Length == 0x100 + modname.Length + allPlain.Length);
var z40 = NsoZbic.Normalize(Make(0xFF, i => frames[i]), "main");
Ck($"N2 0xFF（塞尔达 main 的值，含 0x40）：解开、0x40 保留 → 0x78（实得 0x{BitConverter.ToUInt32(z40, 0x0C):x}）", SegsOk(z40) && BitConverter.ToUInt32(z40, 0x0C) == 0x78);
var lz = Make(0x3F, i => plain[i]); Ck("N3 不带 ZBIC：原样返回同一个数组", ReferenceEquals(NsoZbic.Normalize(lz, "main"), lz));
Ck("N4 负对照：不认识的标志位 0x100 → 报错", Throws(() => NsoZbic.Normalize(Make(0x1BF, i => frames[i]), "main"), "不认识的位 0x100"));
var bad = Make(0xBF, i => frames[i]); bad[0xC0] ^= 1;
Ck("N5 负对照：段哈希不符 → 报错", Throws(() => NsoZbic.Normalize(bad, "main"), "SHA-256"));
var sz = Make(0x87, i => frames[i]); BitConverter.TryWriteBytes(new Span<byte>(sz, 0x18, 4), (uint)plain[0].Length + 1);
Ck("N6 负对照：段大小与解出的不符 → 报错", Throws(() => NsoZbic.Normalize(sz, "main"), "NSO 段 0"));
var std = Make(0xBF, i => i == 2 ? H(FCK) : frames[i]);
Ck("N7 负对照：段里是标准 zstd 帧 → 报红", Throws(() => NsoZbic.Normalize(std, "main"), "标准 zstd"));
int nsoMiss = 0, t0 = BitConverter.ToInt32(z, 0x10);
for (int k = 0; k < frames[0].Length; k++) {
    var b = (byte[])z.Clone(); b[t0 + k] ^= 1; byte[] o = null;
    if (Err(() => o = NsoZbic.Normalize(b, "main")) == null && !(same.Contains(k) && SegsOk(o))) nsoMiss++;
}
Ck($"N8 负对照：text 段 ZBIC 数据逐字节改坏 {frames[0].Length} 处，NSO 规整除解出原文的那 3 处外每处都报错（漏的 {nsoMiss} 处）", nsoMiss == 0);
Console.WriteLine($"{(fail == 0 ? "✓" : "✗")} ZBIC 解码 / NSO 规整：{pass + fail} 项，不通 {fail}");
return fail == 0 ? 0 : 1;
