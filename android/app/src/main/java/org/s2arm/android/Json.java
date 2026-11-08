package org.s2arm.android;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal JSON reader for the Android boot contract. The app only needs objects, arrays,
 * strings, numbers, booleans and null; Android's org.json is not available to the plain-JDK
 * unit tests, so this stays dependency-free. It rejects trailing data and limits nesting.
 */
final class Json {
    private static final int MAX_DEPTH = 64;
    private final String text;
    private final boolean strictNumbers;
    private int pos;

    private Json(String text, boolean strictNumbers) {
        this.text = text;
        this.strictNumbers = strictNumbers;
    }

    static Object parse(String text) {
        return parse(text, false);
    }

    /** F01 imports use JSON number grammar; retain the existing boot-contract entry point. */
    static Object parseStrict(String text) {
        return parse(text, true);
    }

    private static Object parse(String text, boolean strictNumbers) {
        Json p = new Json(text, strictNumbers);
        Object value = p.value(0);
        p.ws();
        if (p.pos != text.length()) throw p.error("trailing data");
        return value;
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> object(Object value, String what) {
        if (!(value instanceof Map)) throw new IllegalArgumentException(what + " is not an object");
        return (Map<String, Object>) value;
    }

    @SuppressWarnings("unchecked")
    static List<Object> array(Object value, String what) {
        if (!(value instanceof List)) throw new IllegalArgumentException(what + " is not an array");
        return (List<Object>) value;
    }

    private IllegalArgumentException error(String message) {
        return new IllegalArgumentException(message + " at byte " + pos);
    }

    private void ws() {
        while (pos < text.length()) {
            char c = text.charAt(pos);
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') pos++;
            else break;
        }
    }

    private Object value(int depth) {
        if (depth > MAX_DEPTH) throw error("nesting too deep");
        ws();
        if (pos >= text.length()) throw error("unexpected end");
        char c = text.charAt(pos);
        switch (c) {
            case '{': return object(depth);
            case '[': return array(depth);
            case '"': return string();
            case 't': literal("true"); return Boolean.TRUE;
            case 'f': literal("false"); return Boolean.FALSE;
            case 'n': literal("null"); return null;
            default:
                if (c == '-' || (c >= '0' && c <= '9')) return number();
                throw error("unexpected character '" + c + "'");
        }
    }

    private Map<String, Object> object(int depth) {
        Map<String, Object> map = new LinkedHashMap<>();
        pos++; // {
        ws();
        if (pos < text.length() && text.charAt(pos) == '}') { pos++; return map; }
        while (true) {
            ws();
            if (pos >= text.length() || text.charAt(pos) != '"') throw error("expected object key");
            String key = string();
            ws();
            if (pos >= text.length() || text.charAt(pos) != ':') throw error("expected ':'");
            pos++;
            if (map.containsKey(key)) throw error("duplicate key '" + key + "'");
            map.put(key, value(depth + 1));
            ws();
            if (pos >= text.length()) throw error("unterminated object");
            char c = text.charAt(pos++);
            if (c == '}') return map;
            if (c != ',') throw error("expected ',' or '}'");
        }
    }

    private List<Object> array(int depth) {
        List<Object> list = new ArrayList<>();
        pos++; // [
        ws();
        if (pos < text.length() && text.charAt(pos) == ']') { pos++; return list; }
        while (true) {
            list.add(value(depth + 1));
            ws();
            if (pos >= text.length()) throw error("unterminated array");
            char c = text.charAt(pos++);
            if (c == ']') return list;
            if (c != ',') throw error("expected ',' or ']'");
        }
    }

    private String string() {
        pos++; // opening quote
        StringBuilder sb = new StringBuilder();
        while (pos < text.length()) {
            char c = text.charAt(pos++);
            if (c == '"') return sb.toString();
            if (c < 0x20) throw error("control character in string");
            if (c != '\\') { sb.append(c); continue; }
            if (pos >= text.length()) throw error("unterminated escape");
            char e = text.charAt(pos++);
            switch (e) {
                case '"': sb.append('"'); break;
                case '\\': sb.append('\\'); break;
                case '/': sb.append('/'); break;
                case 'b': sb.append('\b'); break;
                case 'f': sb.append('\f'); break;
                case 'n': sb.append('\n'); break;
                case 'r': sb.append('\r'); break;
                case 't': sb.append('\t'); break;
                case 'u':
                    if (pos + 4 > text.length()) throw error("short \\u escape");
                    int cp = 0;
                    for (int i = 0; i < 4; i++) {
                        int d = Character.digit(text.charAt(pos++), 16);
                        if (d < 0) throw error("bad \\u escape");
                        cp = (cp << 4) | d;
                    }
                    sb.append((char) cp);
                    break;
                default: throw error("unknown escape \\" + e);
            }
        }
        throw error("unterminated string");
    }

    private Object number() {
        int start = pos;
        if (text.charAt(pos) == '-') pos++;
        while (pos < text.length() && Character.isDigit(text.charAt(pos))) pos++;
        boolean real = false;
        if (pos < text.length() && text.charAt(pos) == '.') {
            real = true;
            pos++;
            while (pos < text.length() && Character.isDigit(text.charAt(pos))) pos++;
        }
        if (pos < text.length() && (text.charAt(pos) == 'e' || text.charAt(pos) == 'E')) {
            real = true;
            pos++;
            if (pos < text.length() && (text.charAt(pos) == '+' || text.charAt(pos) == '-')) pos++;
            while (pos < text.length() && Character.isDigit(text.charAt(pos))) pos++;
        }
        String s = text.substring(start, pos);
        if (strictNumbers && !s.matches("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?"))
            throw error("bad JSON number '" + s + "'");
        try {
            return real ? (Object) Double.parseDouble(s) : (Object) Long.parseLong(s);
        } catch (NumberFormatException e) {
            throw error("bad number '" + s + "'");
        }
    }

    private void literal(String word) {
        if (!text.startsWith(word, pos)) throw error("expected '" + word + "'");
        pos += word.length();
    }
}
