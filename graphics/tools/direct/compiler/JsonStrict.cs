// 严格 JSON 读取：拒绝重复键、注释、尾随逗号、非 UTF-8、NaN/Inf、超深嵌套。
// NativeAOT 正式路径只用 Utf8JsonReader/JsonDocument 与手写写入器，不依赖运行时反射序列化。
using System;
using System.Collections.Generic;
using System.Text.Json;

namespace S2A.DirectCompiler
{
    public sealed class DirectCompileException : Exception
    {
        public readonly string Code;
        public DirectCompileException(string code, string message) : base(message) { Code = code; }
    }

    public static class JsonStrict
    {
        public static void EnsureNoDuplicateKeys(ReadOnlySpan<byte> utf8, int maxDepth = 32)
        {
            var options = new JsonReaderOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = maxDepth,
            };
            var stack = new List<HashSet<string>>();
            try
            {
                var reader = new Utf8JsonReader(utf8, options);
                while (reader.Read())
                {
                    switch (reader.TokenType)
                    {
                        case JsonTokenType.StartObject:
                            stack.Add(new HashSet<string>(StringComparer.Ordinal));
                            break;
                        case JsonTokenType.EndObject:
                            stack.RemoveAt(stack.Count - 1);
                            break;
                        case JsonTokenType.PropertyName:
                            string name = reader.GetString();
                            if (!stack[stack.Count - 1].Add(name))
                                throw new DirectCompileException("DUPLICATE_KEY", "duplicate JSON key: " + name);
                            break;
                    }
                }
            }
            catch (JsonException error)
            {
                throw new DirectCompileException("INVALID_JSON", error.Message);
            }
        }

        public static JsonDocument Parse(byte[] utf8, int maxBytes)
        {
            if (utf8 == null || utf8.Length == 0)
                throw new DirectCompileException("INVALID_JSON", "empty request");
            if (utf8.Length > maxBytes)
                throw new DirectCompileException("RESOURCE_LIMIT", $"request larger than {maxBytes} bytes");
            EnsureNoDuplicateKeys(utf8);
            try
            {
                return JsonDocument.Parse(utf8, new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 32,
                });
            }
            catch (JsonException error)
            {
                throw new DirectCompileException("INVALID_JSON", error.Message);
            }
        }

        public static JsonElement Object(JsonElement parent, string name, string where, bool required = true)
        {
            if (!parent.TryGetProperty(name, out JsonElement value))
            {
                if (required) throw new DirectCompileException("MISSING_FIELD", where + "." + name + " is missing");
                return default;
            }
            if (value.ValueKind != JsonValueKind.Object)
                throw new DirectCompileException("INVALID_JSON", where + "." + name + " is not an object");
            return value;
        }

        public static JsonElement Array(JsonElement parent, string name, string where)
        {
            if (!parent.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.Array)
                throw new DirectCompileException("MISSING_FIELD", where + "." + name + " is missing or not an array");
            return value;
        }

        public static string String(JsonElement parent, string name, string where, int max = 4096)
        {
            if (!parent.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.String)
                throw new DirectCompileException("MISSING_FIELD", where + "." + name + " is missing or not a string");
            string text = value.GetString();
            if (text == null || text.Length > max)
                throw new DirectCompileException("RESOURCE_LIMIT", where + "." + name + " is empty or too long");
            return text;
        }

        public static string OptionalString(JsonElement parent, string name, string where, string fallback, int max = 4096) =>
            parent.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String
                ? value.GetString() : fallback;

        // 可缺省的布尔：缺省用 fallback；出现了但不是布尔就拒绝（不猜）。
        public static bool OptionalBool(JsonElement parent, string name, string where, bool fallback)
        {
            if (!parent.TryGetProperty(name, out JsonElement value)) return fallback;
            if (value.ValueKind != JsonValueKind.True && value.ValueKind != JsonValueKind.False)
                throw new DirectCompileException("INVALID_JSON", where + "." + name + " is not a boolean");
            return value.GetBoolean();
        }

        public static bool Bool(JsonElement parent, string name, string where)
        {
            if (!parent.TryGetProperty(name, out JsonElement value) ||
                (value.ValueKind != JsonValueKind.True && value.ValueKind != JsonValueKind.False))
                throw new DirectCompileException("MISSING_FIELD", where + "." + name + " is missing or not a boolean");
            return value.GetBoolean();
        }

        public static int Int(JsonElement parent, string name, string where, int min, int max)
        {
            if (!parent.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.Number ||
                !value.TryGetInt32(out int number) || number < min || number > max)
                throw new DirectCompileException("MISSING_FIELD", where + "." + name + " is missing or outside " + min + ".." + max);
            return number;
        }

        public static int Int(JsonElement value, string where)
        {
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out int number))
                throw new DirectCompileException("INVALID_JSON", where + " is not an integer");
            return number;
        }

        public static uint UInt32(JsonElement parent, string name, string where, uint min, uint max)
        {
            if (!parent.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.Number ||
                !value.TryGetUInt32(out uint number) || number < min || number > max)
                throw new DirectCompileException("MISSING_FIELD", where + "." + name + " is missing or outside " + min + ".." + max);
            return number;
        }

        public static ulong UInt64(JsonElement parent, string name, string where, ulong min, ulong max)
        {
            if (!parent.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.Number ||
                !value.TryGetUInt64(out ulong number) || number < min || number > max)
                throw new DirectCompileException("MISSING_FIELD", where + "." + name + " is missing or outside " + min + ".." + max);
            return number;
        }

        public static float Float(JsonElement parent, string name, string where)
        {
            if (!parent.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.Number ||
                !value.TryGetSingle(out float number) || !float.IsFinite(number))
                throw new DirectCompileException("MISSING_FIELD", where + "." + name + " is missing or not a finite float");
            return number;
        }

        public static void OnlyKeys(JsonElement element, string where, params string[] allowed)
        {
            var set = new HashSet<string>(allowed, StringComparer.Ordinal);
            foreach (JsonProperty property in element.EnumerateObject())
                if (!set.Contains(property.Name))
                    throw new DirectCompileException("INVALID_JSON", where + " has unknown field " + property.Name);
        }

        public static byte[] Base64(JsonElement parent, string name, string where, int maxBytes)
        {
            string text = String(parent, name, where, (maxBytes + 2) / 3 * 4 + 4);
            try
            {
                byte[] bytes = Convert.FromBase64String(text);
                if (bytes.Length > maxBytes)
                    throw new DirectCompileException("RESOURCE_LIMIT", where + "." + name + " exceeds " + maxBytes + " bytes");
                return bytes;
            }
            catch (FormatException)
            {
                throw new DirectCompileException("INVALID_BASE64", where + "." + name + " is not strict base64");
            }
        }
    }
}
