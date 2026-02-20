const runtime = @import("runtime.zig");
pub const output = @import("output.zig");
pub const builtin = @import("builtin.zig");
pub const read = @import("read.zig");
pub const write = @import("write.zig");
pub const bash = @import("bash.zig");
pub const edit = @import("edit.zig");
pub const grep = @import("grep.zig");
pub const find = @import("find.zig");
pub const ls = @import("ls.zig");
pub const contract_test = @import("contract_test.zig");

pub const Kind = enum {
    read,
    write,
    bash,
    edit,
    grep,
    find,
    ls,
};

pub const Tool = struct {
    kind: Kind,
    desc: []const u8,
    params: []const Param,
    out: OutSpec,
    timeout_ms: u32,
    destructive: bool,

    pub const Param = struct {
        name: []const u8,
        ty: Type,
        required: bool,
        desc: []const u8,
    };

    pub const Type = enum {
        string,
        int,
        bool,
    };

    pub const OutSpec = struct {
        max_bytes: u32,
        stream: bool,
    };
};

pub const Spec = Tool;

pub const Call = struct {
    id: []const u8,
    kind: Kind,
    args: Args,
    src: Source,
    at_ms: i64,

    pub const Source = enum {
        model,
        system,
        replay,
    };

    pub const Args = union(Kind) {
        read: ReadArgs,
        write: WriteArgs,
        bash: BashArgs,
        edit: EditArgs,
        grep: GrepArgs,
        find: FindArgs,
        ls: LsArgs,
    };

    pub const ReadArgs = struct {
        path: []const u8,
        from_line: ?u32 = null,
        to_line: ?u32 = null,
    };

    pub const WriteArgs = struct {
        path: []const u8,
        text: []const u8,
        append: bool = false,
    };

    pub const BashArgs = struct {
        cmd: []const u8,
        cwd: ?[]const u8 = null,
        env: []const Env = &.{},
    };

    pub const EditArgs = struct {
        path: []const u8,
        old: []const u8,
        new: []const u8,
        all: bool = false,
    };

    pub const GrepArgs = struct {
        pattern: []const u8,
        path: []const u8 = ".",
        ignore_case: bool = false,
        max_results: u32 = 200,
    };

    pub const FindArgs = struct {
        name: []const u8,
        path: []const u8 = ".",
        max_results: u32 = 200,
    };

    pub const LsArgs = struct {
        path: []const u8 = ".",
        all: bool = false,
    };

    pub const Env = struct {
        key: []const u8,
        val: []const u8,
    };
};

pub const Output = struct {
    call_id: []const u8,
    seq: u32,
    at_ms: i64,
    stream: Stream,
    chunk: []const u8,
    owned: bool = false,
    truncated: bool = false,

    pub const Stream = enum {
        stdout,
        stderr,
        meta,
    };
};

pub const Result = struct {
    call_id: []const u8,
    started_at_ms: i64,
    ended_at_ms: i64,
    out: []const Output,
    out_owned: bool = false,
    final: Final,

    pub const Final = union(Tag) {
        ok: Ok,
        failed: Failed,
        cancelled: Cancelled,
        timed_out: TimedOut,
    };

    pub const Tag = enum {
        ok,
        failed,
        cancelled,
        timed_out,
    };

    pub const Ok = struct {
        code: i32 = 0,
    };

    pub const Failed = struct {
        code: ?i32 = null,
        kind: ErrKind,
        msg: []const u8,
    };

    pub const Cancelled = struct {
        reason: CancelReason,
    };

    pub const TimedOut = struct {
        limit_ms: u32,
    };

    pub const CancelReason = enum {
        user,
        shutdown,
        superseded,
    };

    pub const ErrKind = enum {
        invalid_args,
        not_found,
        denied,
        io,
        exec,
        internal,
    };
};

pub const Event = union(enum) {
    start: Start,
    output: Output,
    finish: Result,

    pub const Start = struct {
        call: Call,
        at_ms: i64,
    };
};

const rt = runtime.bind(Kind, Spec, Call, Event, Result);

pub const Sink = rt.Sink;
pub const Dispatch = rt.Dispatch;
pub const Entry = rt.Entry;
pub const Registry = rt.Registry;
pub const RegistryErr = rt.Err;
