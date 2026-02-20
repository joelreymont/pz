pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const Req = struct {
    model: []const u8,
    provider: ?[]const u8 = null,
    msgs: []const Msg,
    tools: []const Tool = &.{},
    opts: Opts = .{},
};

pub const Msg = struct {
    role: Role,
    parts: []const Part,
};

pub const Part = union(enum) {
    text: []const u8,
    tool_call: ToolCall,
    tool_result: ToolResult,
};

pub const Tool = struct {
    name: []const u8,
    desc: []const u8 = "",
    schema: []const u8 = "",
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    args: []const u8,
};

pub const ToolResult = struct {
    id: []const u8,
    out: []const u8,
    is_err: bool = false,
};

pub const Opts = struct {
    temp: ?f32 = null,
    top_p: ?f32 = null,
    max_out: ?u32 = null,
    stop: []const []const u8 = &.{},
};

pub const Ev = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call: ToolCall,
    tool_result: ToolResult,
    usage: Usage,
    stop: Stop,
    err: []const u8,
};

pub const Usage = struct {
    in_tok: u64 = 0,
    out_tok: u64 = 0,
    tot_tok: u64 = 0,
};

pub const Stop = struct {
    reason: StopReason,
};

pub const StopReason = enum {
    done,
    max_out,
    tool,
    canceled,
    err,
};

pub const Provider = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        start: *const fn (ctx: *anyopaque, req: Req) anyerror!Stream,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime start_fn: fn (ctx: *T, req: Req) anyerror!Stream,
    ) Provider {
        const Wrap = struct {
            fn start(raw: *anyopaque, req: Req) anyerror!Stream {
                const typed: *T = @ptrCast(@alignCast(raw));
                return start_fn(typed, req);
            }

            const vt = Vt{
                .start = @This().start,
            };
        };

        return .{
            .ctx = ctx,
            .vt = &Wrap.vt,
        };
    }

    pub fn start(self: Provider, req: Req) !Stream {
        return self.vt.start(self.ctx, req);
    }
};

pub const Stream = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        next: *const fn (ctx: *anyopaque) anyerror!?Ev,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime next_fn: fn (ctx: *T) anyerror!?Ev,
        comptime deinit_fn: fn (ctx: *T) void,
    ) Stream {
        const Wrap = struct {
            fn next(raw: *anyopaque) anyerror!?Ev {
                const typed: *T = @ptrCast(@alignCast(raw));
                return next_fn(typed);
            }

            fn deinit(raw: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                deinit_fn(typed);
            }

            const vt = Vt{
                .next = @This().next,
                .deinit = @This().deinit,
            };
        };

        return .{
            .ctx = ctx,
            .vt = &Wrap.vt,
        };
    }

    pub fn next(self: *Stream) !?Ev {
        return self.vt.next(self.ctx);
    }

    pub fn deinit(self: *Stream) void {
        self.vt.deinit(self.ctx);
    }
};
