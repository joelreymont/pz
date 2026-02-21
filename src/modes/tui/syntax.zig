const std = @import("std");
const frame = @import("frame.zig");
const theme = @import("theme.zig");

pub const Kind = enum {
    text,
    keyword,
    string,
    comment,
    number,
    func,
    type_name,
    operator,
    punct,

    pub fn style(k: Kind, base: frame.Style) frame.Style {
        var s = base;
        switch (k) {
            .text => {},
            .keyword => {
                s.fg = theme.get().syn_keyword;
                s.bold = true;
            },
            .string => s.fg = theme.get().syn_string,
            .comment => {
                s.fg = theme.get().syn_comment;
                s.italic = true;
            },
            .number => s.fg = theme.get().syn_number,
            .func => s.fg = theme.get().syn_func,
            .type_name => s.fg = theme.get().syn_type,
            .operator => s.fg = theme.get().syn_operator,
            .punct => {
                s.fg = theme.get().syn_punct;
                s.dim = true;
            },
        }
        return s;
    }
};

pub const Token = struct {
    start: usize,
    end: usize,
    kind: Kind,
};

pub const Lang = enum {
    zig,
    python,
    bash,
    json,
    javascript,
    unknown,

    pub fn detect(hint: []const u8) Lang {
        const map = .{
            .{ "zig", Lang.zig },
            .{ "python", Lang.python },
            .{ "py", Lang.python },
            .{ "bash", Lang.bash },
            .{ "sh", Lang.bash },
            .{ "shell", Lang.bash },
            .{ "zsh", Lang.bash },
            .{ "json", Lang.json },
            .{ "javascript", Lang.javascript },
            .{ "js", Lang.javascript },
            .{ "jsx", Lang.javascript },
            .{ "ts", Lang.javascript },
            .{ "typescript", Lang.javascript },
            .{ "tsx", Lang.javascript },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, hint, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

pub fn tokenize(line: []const u8, lang: Lang, buf: []Token) []const Token {
    return switch (lang) {
        .zig => tokenizeLang(line, buf, .zig),
        .python => tokenizeLang(line, buf, .python),
        .bash => tokenizeLang(line, buf, .bash),
        .json => tokenizeJson(line, buf),
        .javascript => tokenizeLang(line, buf, .javascript),
        .unknown => tokenizeGeneric(line, buf),
    };
}

// --- Language configs ---

const LangCfg = struct {
    keywords: []const []const u8,
    line_comment: ?[]const u8,
    hash_comment: bool,
    has_single_quote_str: bool,
    has_types: bool, // PascalCase detection
};

fn langCfg(comptime lang: Lang) LangCfg {
    return switch (lang) {
        .zig => .{
            .keywords = &zig_kw,
            .line_comment = "//",
            .hash_comment = false,
            .has_single_quote_str = false,
            .has_types = true,
        },
        .python => .{
            .keywords = &python_kw,
            .line_comment = null,
            .hash_comment = true,
            .has_single_quote_str = true,
            .has_types = false,
        },
        .bash => .{
            .keywords = &bash_kw,
            .line_comment = null,
            .hash_comment = true,
            .has_single_quote_str = true,
            .has_types = false,
        },
        .javascript => .{
            .keywords = &js_kw,
            .line_comment = "//",
            .hash_comment = false,
            .has_single_quote_str = true,
            .has_types = false,
        },
        else => unreachable,
    };
}

const zig_kw = [_][]const u8{
    "and",      "break",     "catch",  "comptime",    "const",
    "continue", "defer",     "else",   "enum",        "errdefer",
    "error",    "false",     "fn",     "for",         "if",
    "inline",   "null",      "or",     "orelse",      "pub",
    "return",   "struct",    "switch", "test",        "true",
    "try",      "undefined", "union",  "unreachable", "var",
    "while",
};

const python_kw = [_][]const u8{
    "False",    "None",    "True",  "and",   "as",
    "assert",   "async",   "await", "break", "class",
    "continue", "def",     "del",   "elif",  "else",
    "except",   "finally", "for",   "from",  "global",
    "if",       "import",  "in",    "is",    "lambda",
    "not",      "or",      "pass",  "raise", "return",
    "try",      "while",   "with",  "yield",
};

const bash_kw = [_][]const u8{
    "case",  "do",       "done", "echo",   "elif",
    "else",  "esac",     "exit", "export", "fi",
    "for",   "function", "if",   "local",  "return",
    "set",   "source",   "then", "unset",  "until",
    "while",
};

const js_kw = [_][]const u8{
    "async",    "await", "break",    "case",       "catch",
    "class",    "const", "continue", "else",       "export",
    "extends",  "false", "finally",  "for",        "from",
    "function", "if",    "import",   "instanceof", "let",
    "new",      "null",  "return",   "switch",     "this",
    "throw",    "true",  "try",      "typeof",     "undefined",
    "var",      "while", "yield",
};

fn isKw(comptime keywords: []const []const u8, word: []const u8) bool {
    inline for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

// --- Generic tokenizer (no keywords, just strings/numbers/operators) ---

fn tokenizeGeneric(line: []const u8, buf: []Token) []const Token {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < buf.len) {
        // String
        if (line[i] == '"' or line[i] == '\'') {
            const end = scanStr(line, i);
            buf[n] = .{ .start = i, .end = end, .kind = .string };
            n += 1;
            i = end;
            continue;
        }
        // Number
        if (isDigit(line[i]) and (i == 0 or !isIdentChar(line[i - 1]))) {
            const end = scanNum(line, i);
            buf[n] = .{ .start = i, .end = end, .kind = .number };
            n += 1;
            i = end;
            continue;
        }
        // Operator
        if (isOp(line[i])) {
            buf[n] = .{ .start = i, .end = i + 1, .kind = .operator };
            n += 1;
            i += 1;
            continue;
        }
        // Punct
        if (isPunct(line[i])) {
            buf[n] = .{ .start = i, .end = i + 1, .kind = .punct };
            n += 1;
            i += 1;
            continue;
        }
        // Text (identifiers / whitespace / anything else)
        const start = i;
        if (isIdentStart(line[i])) {
            i += 1;
            while (i < line.len and isIdentChar(line[i])) : (i += 1) {}
        } else {
            i += 1;
        }
        buf[n] = .{ .start = start, .end = i, .kind = .text };
        n += 1;
    }
    return buf[0..n];
}

// --- Main language tokenizer ---

fn tokenizeLang(line: []const u8, buf: []Token, comptime lang: Lang) []const Token {
    const cfg = comptime langCfg(lang);
    var n: usize = 0;
    var i: usize = 0;

    while (i < line.len and n < buf.len) {
        // Line comment: //
        if (cfg.line_comment) |lc| {
            if (i + lc.len <= line.len and std.mem.eql(u8, line[i..][0..lc.len], lc)) {
                buf[n] = .{ .start = i, .end = line.len, .kind = .comment };
                return buf[0 .. n + 1];
            }
        }
        // Hash comment
        if (cfg.hash_comment and line[i] == '#') {
            buf[n] = .{ .start = i, .end = line.len, .kind = .comment };
            return buf[0 .. n + 1];
        }

        // String (double quote)
        if (line[i] == '"') {
            const end = scanStr(line, i);
            buf[n] = .{ .start = i, .end = end, .kind = .string };
            n += 1;
            i = end;
            continue;
        }
        // String (single quote)
        if (cfg.has_single_quote_str and line[i] == '\'') {
            const end = scanStr(line, i);
            buf[n] = .{ .start = i, .end = end, .kind = .string };
            n += 1;
            i = end;
            continue;
        }
        // Zig char literal: 'x' (single char, not single-quote string)
        if (!cfg.has_single_quote_str and line[i] == '\'') {
            const end = scanStr(line, i);
            buf[n] = .{ .start = i, .end = end, .kind = .string };
            n += 1;
            i = end;
            continue;
        }

        // Number (not preceded by ident char)
        if (isDigit(line[i]) and (i == 0 or !isIdentChar(line[i - 1]))) {
            const end = scanNum(line, i);
            buf[n] = .{ .start = i, .end = end, .kind = .number };
            n += 1;
            i = end;
            continue;
        }

        // Identifier / keyword / type / func
        if (isIdentStart(line[i]) or line[i] == '@') {
            const start = i;
            if (line[i] == '@') i += 1;
            while (i < line.len and isIdentChar(line[i])) : (i += 1) {}
            const word = line[start..i];

            // Check keyword
            if (isKw(cfg.keywords, word)) {
                buf[n] = .{ .start = start, .end = i, .kind = .keyword };
                n += 1;
                continue;
            }
            // Check function call: ident followed by '('
            if (i < line.len and line[i] == '(') {
                buf[n] = .{ .start = start, .end = i, .kind = .func };
                n += 1;
                continue;
            }
            // PascalCase type detection for Zig
            if (cfg.has_types and isPascalCase(word)) {
                buf[n] = .{ .start = start, .end = i, .kind = .type_name };
                n += 1;
                continue;
            }
            buf[n] = .{ .start = start, .end = i, .kind = .text };
            n += 1;
            continue;
        }

        // Operator
        if (isOp(line[i])) {
            buf[n] = .{ .start = i, .end = i + 1, .kind = .operator };
            n += 1;
            i += 1;
            continue;
        }
        // Punct
        if (isPunct(line[i])) {
            buf[n] = .{ .start = i, .end = i + 1, .kind = .punct };
            n += 1;
            i += 1;
            continue;
        }

        // Whitespace / other
        const start = i;
        i += 1;
        buf[n] = .{ .start = start, .end = i, .kind = .text };
        n += 1;
    }
    return buf[0..n];
}

// --- JSON tokenizer ---

fn tokenizeJson(line: []const u8, buf: []Token) []const Token {
    var n: usize = 0;
    var i: usize = 0;

    while (i < line.len and n < buf.len) {
        // String (key or value)
        if (line[i] == '"') {
            const end = scanStr(line, i);
            // Determine if this is a key (followed by ':')
            var j = end;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
            const kind: Kind = if (j < line.len and line[j] == ':') .func else .string;
            buf[n] = .{ .start = i, .end = end, .kind = kind };
            n += 1;
            i = end;
            continue;
        }
        // Numbers
        if ((isDigit(line[i]) or (line[i] == '-' and i + 1 < line.len and isDigit(line[i + 1]))) and
            (i == 0 or !isIdentChar(line[i - 1])))
        {
            const end = scanNum(line, i);
            buf[n] = .{ .start = i, .end = end, .kind = .number };
            n += 1;
            i = end;
            continue;
        }
        // Booleans / null
        if (isIdentStart(line[i])) {
            const start = i;
            while (i < line.len and isIdentChar(line[i])) : (i += 1) {}
            const word = line[start..i];
            const kind: Kind = if (std.mem.eql(u8, word, "true") or
                std.mem.eql(u8, word, "false") or
                std.mem.eql(u8, word, "null")) .keyword else .text;
            buf[n] = .{ .start = start, .end = i, .kind = kind };
            n += 1;
            continue;
        }
        // Punct
        if (isPunct(line[i]) or line[i] == ':') {
            buf[n] = .{ .start = i, .end = i + 1, .kind = .punct };
            n += 1;
            i += 1;
            continue;
        }
        // Whitespace / other
        const start = i;
        i += 1;
        buf[n] = .{ .start = start, .end = i, .kind = .text };
        n += 1;
    }
    return buf[0..n];
}

// --- Scanner helpers ---

fn scanStr(line: []const u8, pos: usize) usize {
    const quote = line[pos];
    var i = pos + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (line[i] == quote) return i + 1;
    }
    return i; // unterminated
}

fn scanNum(line: []const u8, pos: usize) usize {
    var i = pos;
    // Leading minus for JSON
    if (i < line.len and line[i] == '-') i += 1;
    // Hex/binary prefix
    if (i + 1 < line.len and line[i] == '0') {
        if (line[i + 1] == 'x' or line[i + 1] == 'X' or
            line[i + 1] == 'b' or line[i + 1] == 'B' or
            line[i + 1] == 'o' or line[i + 1] == 'O')
        {
            i += 2;
            while (i < line.len and (isHexDigit(line[i]) or line[i] == '_')) : (i += 1) {}
            return i;
        }
    }
    while (i < line.len and (isDigit(line[i]) or line[i] == '_')) : (i += 1) {}
    // Float
    if (i < line.len and line[i] == '.') {
        i += 1;
        while (i < line.len and (isDigit(line[i]) or line[i] == '_')) : (i += 1) {}
    }
    // Exponent
    if (i < line.len and (line[i] == 'e' or line[i] == 'E')) {
        i += 1;
        if (i < line.len and (line[i] == '+' or line[i] == '-')) i += 1;
        while (i < line.len and isDigit(line[i])) : (i += 1) {}
    }
    return i;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn isOp(c: u8) bool {
    return switch (c) {
        '=', '+', '-', '*', '/', '<', '>', '!', '&', '|', '^', '~', '%' => true,
        else => false,
    };
}

fn isPunct(c: u8) bool {
    return switch (c) {
        '(', ')', '{', '}', '[', ']', ',', ';', '.' => true,
        else => false,
    };
}

fn isPascalCase(word: []const u8) bool {
    if (word.len < 2) return false;
    // Must start with uppercase
    if (word[0] < 'A' or word[0] > 'Z') return false;
    // Must contain at least one lowercase
    for (word[1..]) |c| {
        if (c >= 'a' and c <= 'z') return true;
    }
    return false;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Lang.detect maps known hints" {
    try testing.expectEqual(Lang.zig, Lang.detect("zig"));
    try testing.expectEqual(Lang.python, Lang.detect("py"));
    try testing.expectEqual(Lang.python, Lang.detect("python"));
    try testing.expectEqual(Lang.bash, Lang.detect("sh"));
    try testing.expectEqual(Lang.bash, Lang.detect("bash"));
    try testing.expectEqual(Lang.bash, Lang.detect("zsh"));
    try testing.expectEqual(Lang.json, Lang.detect("json"));
    try testing.expectEqual(Lang.javascript, Lang.detect("js"));
    try testing.expectEqual(Lang.javascript, Lang.detect("javascript"));
    try testing.expectEqual(Lang.javascript, Lang.detect("ts"));
    try testing.expectEqual(Lang.unknown, Lang.detect("haskell"));
    try testing.expectEqual(Lang.unknown, Lang.detect(""));
}

test "zig: keywords highlighted" {
    var buf: [64]Token = undefined;
    const toks = tokenize("const x = 1;", .zig, &buf);
    // First token should be keyword "const"
    try testing.expectEqual(Kind.keyword, toks[0].kind);
    try testing.expectEqualStrings("const", "const x = 1;"[toks[0].start..toks[0].end]);
}

test "zig: string literal" {
    var buf: [64]Token = undefined;
    const line = "const s = \"hello\";";
    const toks = tokenize(line, .zig, &buf);
    var found = false;
    for (toks) |t| {
        if (t.kind == .string) {
            try testing.expectEqualStrings("\"hello\"", line[t.start..t.end]);
            found = true;
        }
    }
    try testing.expect(found);
}

test "zig: line comment" {
    var buf: [64]Token = undefined;
    const line = "x + 1 // add one";
    const toks = tokenize(line, .zig, &buf);
    const last = toks[toks.len - 1];
    try testing.expectEqual(Kind.comment, last.kind);
    try testing.expectEqualStrings("// add one", line[last.start..last.end]);
}

test "zig: number literals" {
    var buf: [64]Token = undefined;
    const line = "0xff + 42 + 3.14";
    const toks = tokenize(line, .zig, &buf);
    try testing.expectEqual(Kind.number, toks[0].kind);
    try testing.expectEqualStrings("0xff", line[toks[0].start..toks[0].end]);
}

test "zig: function call" {
    var buf: [64]Token = undefined;
    const line = "foo(bar)";
    const toks = tokenize(line, .zig, &buf);
    try testing.expectEqual(Kind.func, toks[0].kind);
    try testing.expectEqualStrings("foo", line[toks[0].start..toks[0].end]);
}

test "zig: PascalCase type" {
    var buf: [64]Token = undefined;
    const line = "var x: MyType = .{};";
    const toks = tokenize(line, .zig, &buf);
    var found = false;
    for (toks) |t| {
        if (t.kind == .type_name) {
            try testing.expectEqualStrings("MyType", line[t.start..t.end]);
            found = true;
        }
    }
    try testing.expect(found);
}

test "python: keywords and hash comment" {
    var buf: [64]Token = undefined;
    const line = "def foo(): # comment";
    const toks = tokenize(line, .python, &buf);
    try testing.expectEqual(Kind.keyword, toks[0].kind);
    try testing.expectEqualStrings("def", line[toks[0].start..toks[0].end]);
    const last = toks[toks.len - 1];
    try testing.expectEqual(Kind.comment, last.kind);
}

test "python: single-quote string" {
    var buf: [64]Token = undefined;
    const line = "x = 'hello'";
    const toks = tokenize(line, .python, &buf);
    var found = false;
    for (toks) |t| {
        if (t.kind == .string) {
            try testing.expectEqualStrings("'hello'", line[t.start..t.end]);
            found = true;
        }
    }
    try testing.expect(found);
}

test "bash: keywords" {
    var buf: [64]Token = undefined;
    const line = "if [ -f file ]; then";
    const toks = tokenize(line, .bash, &buf);
    try testing.expectEqual(Kind.keyword, toks[0].kind);
    try testing.expectEqualStrings("if", line[toks[0].start..toks[0].end]);
}

test "javascript: keywords and comment" {
    var buf: [64]Token = undefined;
    const line = "const x = 42; // num";
    const toks = tokenize(line, .javascript, &buf);
    try testing.expectEqual(Kind.keyword, toks[0].kind);
    const last = toks[toks.len - 1];
    try testing.expectEqual(Kind.comment, last.kind);
}

test "json: key vs string value" {
    var buf: [64]Token = undefined;
    const line = "  \"name\": \"alice\"";
    const toks = tokenize(line, .json, &buf);
    // Find the key and value
    var key_found = false;
    var val_found = false;
    for (toks) |t| {
        if (t.kind == .func) {
            try testing.expectEqualStrings("\"name\"", line[t.start..t.end]);
            key_found = true;
        }
        if (t.kind == .string) {
            try testing.expectEqualStrings("\"alice\"", line[t.start..t.end]);
            val_found = true;
        }
    }
    try testing.expect(key_found);
    try testing.expect(val_found);
}

test "json: boolean and null keywords" {
    var buf: [64]Token = undefined;
    const line = "true false null";
    const toks = tokenize(line, .json, &buf);
    for (toks) |t| {
        if (t.kind != .text) {
            try testing.expectEqual(Kind.keyword, t.kind);
        }
    }
}

test "operators and punctuation" {
    var buf: [64]Token = undefined;
    const line = "a + b(c);";
    const toks = tokenize(line, .zig, &buf);
    var has_op = false;
    var has_punct = false;
    for (toks) |t| {
        if (t.kind == .operator) has_op = true;
        if (t.kind == .punct) has_punct = true;
    }
    try testing.expect(has_op);
    try testing.expect(has_punct);
}

test "escaped string characters" {
    var buf: [64]Token = undefined;
    const line = "\"he\\\"llo\"";
    const toks = tokenize(line, .zig, &buf);
    try testing.expectEqual(Kind.string, toks[0].kind);
    try testing.expectEqualStrings(line, line[toks[0].start..toks[0].end]);
}

test "unknown lang uses generic tokenizer" {
    var buf: [64]Token = undefined;
    const line = "x = \"hi\" + 42";
    const toks = tokenize(line, .unknown, &buf);
    var has_str = false;
    var has_num = false;
    for (toks) |t| {
        if (t.kind == .string) has_str = true;
        if (t.kind == .number) has_num = true;
    }
    try testing.expect(has_str);
    try testing.expect(has_num);
}
