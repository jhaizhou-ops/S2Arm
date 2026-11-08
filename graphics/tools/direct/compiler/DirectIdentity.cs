// 编译器构建身份的可读出口：CLI（identity）、出包生产者与设备核对都从这里读，
// 值来自构建期生成的 DirectBuildIdentity（closure.py 按源闭包算出），没有第二份手抄常量。
using System.Text.Json;

namespace S2A.DirectCompiler
{
    public static class DirectIdentity
    {
        public const string Schema = "s2a-direct-identity-v1";

        public static string TranslatorClosure => DirectBuildIdentity.TranslatorClosure;

        public static string Rule => DirectBuildIdentity.Rule;

        // 二进制身份：同一源码闭包可以有几个部署产物（CLI / NativeAOT），MVID 证明"部署的是哪一次
        // 构建"，和证明"翻译语义"的 SourcesDigest 分列。不拿仓库 HEAD、编译时间或文件存在冒充。
        public static string ModuleVersionId =>
            typeof(DirectShaderCompiler).Assembly.ManifestModule.ModuleVersionId.ToString("N");

        // 生产者用它拿 closure；身份与二进制摘要分开：SourcesDigest 证明翻译语义，
        // 部署物是不是同一构建由 ModuleVersionId 证明。
        public static string Json() => JsonSerializer.Serialize(new
        {
            schema = Schema,
            rule = DirectBuildIdentity.Rule,
            translatorClosure = DirectBuildIdentity.TranslatorClosure,
            sourcesDigest = DirectBuildIdentity.SourcesDigest,
            moduleVersionId = ModuleVersionId,
            sources = DirectBuildIdentity.SourceCount,
            bytes = DirectBuildIdentity.SourceBytes,
            compilerABI = DirectProfile.CompilerAbi,
            directABI = 1,
            supportLayout = SupportLayout.Compile().Hash,
        });
    }
}
