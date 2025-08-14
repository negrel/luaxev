const std = @import("std");
const builtin = @import("builtin");

const xev = @import("libxev");
const zlj = @import("zluajit");
const testing = std.testing;

pub export fn luaopen_xev(l: ?*zlj.c.lua_State) callconv(.c) c_int {
    const lua = zlj.State.initFromCPointer(l.?);

    lua.pushModule("xev", 0);
    const mod = lua.toAnyType(zlj.TableRef, -1).?;

    // Loop.
    {
        lua.newTable();
        const loop = lua.toAnyType(zlj.TableRef, -1).?;
        mod.set("Loop", loop);
        loop.set("new", Loop.new);
    }

    // File.
    {
        lua.newTable();
        const file = lua.toAnyType(zlj.TableRef, -1).?;
        mod.set("File", file);
        file.set("open", File.open);
    }

    // Completion.
    {
        lua.newTable();
        const completion = lua.toAnyType(zlj.TableRef, -1).?;
        mod.set("Completion", completion);
        completion.set("new", Completion.new);
    }

    // ReadBuffer.
    {
        lua.newTable();
        const read_buffer = lua.toAnyType(zlj.TableRef, -1).?;
        mod.set("ReadBuffer", read_buffer);
        read_buffer.set("new", Buffer.new);
    }

    return 0;
}

const Loop = struct {
    const Self = @This();
    const tname = "xev.Loop";

    fn new(lua: zlj.State) c_int {
        const loop = lua.newUserData(xev.Loop);

        if (lua.newMetaTable(xev.Loop, Self.tname)) {
            const mt = lua.toAnyType(zlj.TableRef, -1).?;

            // Meta methods.
            {
                mt.set("__gc", zlj.wrapFn(xev.Loop.deinit));
                mt.set("__metatable", false);
            }

            // Create __index table.
            {
                lua.newTable();
                const index = lua.toAnyType(zlj.TableRef, -1).?;
                defer lua.pop(1);
                index.set("run", Self.run);
                mt.set("__index", index);
            }
        }
        lua.setMetaTable(1);

        loop.* = xev.Loop.init(.{}) catch |err| lua.raiseError(err);

        return 1;
    }

    fn run(lua: zlj.State) c_int {
        const loop = lua.checkUserData(1, xev.Loop, Self.tname);
        const mode = lua.checkEnum(2, xev.RunMode, null);

        loop.run(mode) catch |err| lua.raiseError(err);

        return 0;
    }
};

const File = struct {
    const Self = @This();
    const tname = "xev.File";

    fn open(lua: zlj.State) c_int {
        const fd = lua.checkAnyType(1, std.fs.File.Handle);

        const f = lua.newUserData(xev.File);

        if (lua.newMetaTable(xev.File, Self.tname)) {
            const mt = lua.toAnyType(zlj.TableRef, -1).?;

            // Meta methods.
            {
                mt.set("__gc", zlj.wrapFn(xev.File.deinit));
                mt.set("__metatable", false);
            }

            // Create __index table.
            {
                lua.newTable();
                const index = lua.toAnyType(zlj.TableRef, -1).?;
                defer lua.pop(1);
                index.set("read", Self.read);
                mt.set("__index", index);
            }
        }
        lua.setMetaTable(2);

        f.* = xev.File.initFd(fd);

        return 1;
    }

    pub fn read(lua: zlj.State) c_int {
        const f = lua.checkUserData(1, xev.File, Self.tname);
        const loop = lua.checkUserData(2, xev.Loop, Loop.tname);
        const c = lua.checkUserData(3, xev.Completion, Completion.tname);
        const rb = lua.checkUserData(4, []u8, Buffer.tname);
        lua.checkValueType(5, .function); // Callback.

        // Remove extra args.
        if (lua.top() > 5) lua.pop(lua.top() - 5);

        const alloc = (lua.allocator() orelse &std.heap.c_allocator).*;
        const callback = ReadCallback.init(alloc, lua) catch |err| {
            lua.raiseError(err);
        };

        // Add read task.
        f.read(
            loop,
            c,
            .{ .slice = rb.* },
            ReadCallback,
            callback,
            ReadCallback.readCallback,
        );

        return 0;
    }
};

const Completion = struct {
    const Self = @This();
    const tname = "xev.Completion";

    pub fn new(lua: zlj.State) c_int {
        _ = lua.newUserData(xev.Completion);

        if (lua.newMetaTable(xev.Completion, Self.tname)) {
            const mt = lua.toAnyType(zlj.TableRef, -1).?;

            // Meta methods.
            {
                mt.set("__metatable", false);
            }

            // Create __index table.
            {
                lua.newTable();
                const index = lua.toAnyType(zlj.TableRef, -1).?;
                defer lua.pop(1);
                mt.set("__index", index);
            }
        }
        lua.setMetaTable(1);

        return 1;
    }
};

const Buffer = struct {
    const Self = @This();
    const tname = "xev.Buffer";

    slice: []u8,
    len: usize = 0,

    pub fn new(lua: zlj.State) c_int {
        const size = lua.optInteger(1, 4096);
        if (size < 0) lua.raiseError(error.NegativeSize);

        const self = lua.newUserData(Self);
        const alloc = (lua.allocator() orelse &std.heap.c_allocator).*;
        self.slice = alloc.alloc(u8, @intCast(size)) catch |err| lua.raiseError(err);

        if (lua.newMetaTable(xev.Completion, Self.tname)) {
            const mt = lua.toAnyType(zlj.TableRef, -1).?;

            // Meta methods.
            {
                mt.set("__gc", Self.gc);
                mt.set("__metatable", false);
                mt.set("__tostring", Self.toString);
            }

            // Create __index table.
            {
                lua.newTable();
                const index = lua.toAnyType(zlj.TableRef, -1).?;
                defer lua.pop(1);
                index.set("tostring", Self.toString);
                mt.set("__index", index);
            }
        }
        lua.setMetaTable(1);

        return 1;
    }

    pub fn gc(lua: zlj.State) c_int {
        const self = lua.checkUserData(1, Self, Self.tname);
        const alloc = (lua.allocator() orelse &std.heap.c_allocator).*;
        alloc.free(self.slice);
        return 0;
    }

    pub fn toString(lua: zlj.State) c_int {
        const self = lua.checkUserData(1, Self, "xev.Buffer");
        lua.pushString(self.slice[0..self.len]);
        return 1;
    }
};

const ReadCallback = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    lua: zlj.State,
    cb_ref: c_int,
    buf_ref: c_int,

    /// Initialize a Callback using function on top of the stack.
    pub fn init(alloc: std.mem.Allocator, lua: zlj.State) !*Self {
        const self = try alloc.create(Self);
        self.alloc = alloc;
        self.lua = lua;
        self.cb_ref = try lua.ref(zlj.Registry);
        self.buf_ref = try lua.ref(zlj.Registry);
        return self;
    }

    fn deinit(self: *Self) void {
        self.lua.unref(zlj.Registry, self.cb_ref);
        self.lua.unref(zlj.Registry, self.buf_ref);
        self.alloc.destroy(self);
    }

    pub fn readCallback(
        ud: ?*ReadCallback,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = ud.?;

        self.lua.rawGeti(zlj.Registry, self.cb_ref);

        if (r) |read| {
            self.lua.rawGeti(zlj.Registry, self.buf_ref);
            const buf = self.lua.popAnyType(*Buffer).?;
            buf.len = read;
            self.lua.pushInteger(@intCast(read));
            self.lua.call(1, 1);
        } else |err| {
            self.lua.pushInteger(0);
            self.lua.pushString(@errorName(err));
            self.lua.call(2, 1);
        }

        if (self.lua.toBoolean(-1)) return .rearm;

        self.deinit();

        return .disarm;
    }
};

// fn loopDeinit(lua: LuaState) callconv(.c) c_int {
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     _ = loop;
//     // loop.deinit();
//     return 0;
// }
//
// fn loopStop(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(0);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     loop.stop();
//     return 0;
// }
//
// fn loopStopped(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(1);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     c.lua_pushboolean(lua, @intFromBool(loop.stopped()));
//     return 1;
// }
//
// fn loopAdd(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(0);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     const comp: *xev.Completion = @ptrCast(@alignCast(c.luaL_checkudata(lua, 2, "xev.Completion").?));
//
//     loop.add(comp);
//
//     return 0;
// }
//
// fn loopSubmit(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(0);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     loop.submit() catch |err| return c.luaL_error(lua, @errorName(err));
//
//     return 0;
// }
//
// fn loopRun(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(0);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     const mode_str = checkString(lua, 2);
//
//     var mode: xev.RunMode = undefined;
//     if (std.mem.eql(u8, mode_str, "no_wait")) {
//         mode = .no_wait;
//     } else if (std.mem.eql(u8, mode_str, "once")) {
//         mode = .once;
//     } else if (std.mem.eql(u8, mode_str, "until_done")) {
//         mode = .until_done;
//     } else {
//         return c.luaL_error(lua, "unknown xev.RunMode");
//     }
//
//     loop.run(mode) catch |err| return c.luaL_error(lua, @errorName(err));
//
//     return 0;
// }
//
// fn loopTick(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(0);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     const wait: c_long = c.luaL_checkinteger(lua, 2);
//
//     if (wait < 0) {
//         return c.luaL_error(lua, "wait must be positive");
//     }
//
//     loop.tick(@intCast(wait)) catch |err| c.luaL_error(lua, @errorName(err));
//
//     return 0;
// }
//
// fn loopNow(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(1);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     c.lua_pushinteger(lua, loop.now());
//     return 1;
// }
//
// fn loopUpdateNow(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(0);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     loop.update_now();
//     return 0;
// }
//
// fn loopTimer(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(0);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     const comp: *xev.Completion = @ptrCast(@alignCast(c.luaL_checkudata(lua, 2, "xev.Completion").?));
//     const next_ms: c.lua_Integer = c.luaL_checkinteger(lua, 3);
//
//     if (next_ms < 0 or next_ms > std.math.maxInt(u64)) {
//         return c.luaL_error(lua, "next_ms must be an integer between 0 and std.math.maxInt(u64)");
//     }
//
//     // REGISTRY[ctx] = callback;
//     const ctx: *CallbackContext = @ptrCast(@alignCast(c.lua_newuserdata(lua, @sizeOf(CallbackContext))));
//     c.lua_pushvalue(lua, 5);
//     c.lua_settable(lua, c.LUA_REGISTRYINDEX);
//
//     loop.timer(comp, @intCast(next_ms), ctx, luaCallback);
//
//     return 0;
// }
//
// fn loopTimerReset(lua: LuaState) callconv(.c) c_int {
//     const sg = StackGuard.init(lua);
//     defer sg.check(0);
//
//     const loop: *xev.Loop = @ptrCast(@alignCast(c.luaL_checkudata(lua, 1, "xev.Loop").?));
//     const comp: *xev.Completion = @ptrCast(@alignCast(c.luaL_checkudata(lua, 2, "xev.Completion").?));
//     const comp_cancel: *xev.Completion = @ptrCast(@alignCast(c.luaL_checkudata(lua, 3, "xev.Completion").?));
//     const next_ms: c.lua_Integer = c.luaL_checkinteger(lua, 4);
//     c.luaL_checktype(lua, 5, c.LUA_TFUNCTION);
//
//     if (next_ms < 0 or next_ms > std.math.maxInt(u64)) {
//         return c.luaL_error(lua, "next_ms must be an integer between 0 and std.math.maxInt(u64)");
//     }
//
//     // REGISTRY[ctx] = callback;
//     const ctx: *CallbackContext = @ptrCast(@alignCast(c.lua_newuserdata(lua, @sizeOf(CallbackContext))));
//     c.lua_pushvalue(lua, 5);
//     c.lua_settable(lua, c.LUA_REGISTRYINDEX);
//
//     loop.timer_reset(comp, comp_cancel, @intCast(next_ms), ctx, luaCallback);
//
//     return 0;
// }
//
// fn luaCallback(
//     userdata: ?*anyopaque,
//     loop: *xev.Loop,
//     completion: *xev.Completion,
//     result: xev.Result,
// ) xev.CallbackAction {
//     const ctx: *CallbackContext = @ptrCast(@alignCast(userdata.?));
//     const lua = ctx.lua;
//
//     const sg = StackGuard.init(lua);
//     defer sg.check(0);
//
//     // Retrieve REGISTRY[ctx].
//     c.lua_pushlightuserdata(lua, ctx);
//     c.lua_gettable(lua, c.LUA_REGISTRYINDEX);
//     c.luaL_checktype(lua, -1, c.LUA_TFUNCTION);
//
//     // Remove REGISTRY[ctx].
//     c.lua_pushlightuserdata(lua, ctx);
//     c.lua_pushnil(lua);
//     c.lua_settable(lua, c.LUA_REGISTRYINDEX);
//
//     // Execute callback.
//     c.lua_pushlightuserdata(lua, loop);
//     c.luaL_setmetatable(lua, "xev.Loop");
//     c.lua_pushlightuserdata(lua, completion);
//     c.luaL_setmetatable(lua, "xev.Completion");
//     _ = pushCopy(lua, @TypeOf(result), result);
//     c.lua_call(lua, 3, 1);
//
//     const action_str = toString(lua, -1).?;
//     var action: xev.CallbackAction = undefined;
//     if (std.mem.eql(u8, action_str, "disarm")) {
//         action = .disarm;
//     } else if (std.mem.eql(u8, action_str, "rearm")) {
//         action = .rearm;
//     } else {
//         _ = c.luaL_error(lua, "unknown xev.CallbackAction");
//     }
//
//     return action;
// }
