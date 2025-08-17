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

    // ReadBuffer.
    {
        lua.newTable();
        const read_buffer = lua.toAnyType(zlj.TableRef, -1).?;
        mod.set("ReadBuffer", read_buffer);
        read_buffer.set("new", Buffer.new);
    }

    return 0;
}

fn getAlloc(lua: zlj.State) std.mem.Allocator {
    return (lua.allocator() orelse &std.heap.c_allocator).*;
}

const Loop = struct {
    const Self = @This();
    const tname = "xev.Loop";

    fn new(lua: zlj.State) !c_int {
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

        loop.* = try xev.Loop.init(.{});

        return 1;
    }

    fn run(lua: zlj.State) !c_int {
        const loop = lua.checkUserData(1, xev.Loop, Self.tname);
        const mode = lua.checkEnum(2, xev.RunMode, null);

        try loop.run(mode);

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
                index.set("pread", Self.pread);
                index.set("write", Self.write);
                index.set("pwrite", Self.pwrite);
                index.set("close", Self.close);
                mt.set("__index", index);
            }
        }
        lua.setMetaTable(2);

        f.* = xev.File.initFd(fd);

        return 1;
    }

    pub fn read(lua: zlj.State) !c_int {
        const f = lua.checkUserData(1, xev.File, Self.tname);
        const loop = lua.checkUserData(2, xev.Loop, Loop.tname);
        const buf = lua.checkUserData(3, Buffer, Buffer.tname);
        lua.checkValueType(4, .function); // Callback.
        lua.setTop(4);

        const callback = try ReadCallback.init(lua);

        f.read(
            loop,
            try getAlloc(lua).create(xev.Completion),
            .{ .slice = buf.slice },
            ReadCallback,
            callback,
            ReadCallback.readCallback,
        );

        return 0;
    }

    pub fn pread(lua: zlj.State) !c_int {
        const f = lua.checkUserData(1, xev.File, Self.tname);
        const loop = lua.checkUserData(2, xev.Loop, Loop.tname);
        const buf = lua.checkUserData(3, Buffer, Buffer.tname);
        const offset: usize = @intCast(lua.checkLong(4));
        lua.checkValueType(5, .function); // Callback.
        lua.setTop(5);

        // Remove offset from stack.
        lua.remove(4);
        const callback = try ReadCallback.init(lua);
        f.pread(
            loop,
            try getAlloc(lua).create(xev.Completion),
            .{ .slice = buf.slice },
            offset,
            ReadCallback,
            callback,
            ReadCallback.readCallback,
        );

        return 0;
    }

    pub fn write(lua: zlj.State) !c_int {
        const f = lua.checkUserData(1, xev.File, Self.tname);
        const loop = lua.checkUserData(2, xev.Loop, Loop.tname);
        const str = lua.checkString(3);
        lua.checkValueType(4, .function); // Callback.
        lua.setTop(4);

        const callback = try WriteCallback.init(lua);
        f.write(
            loop,
            try getAlloc(lua).create(xev.Completion),
            .{ .slice = str },
            WriteCallback,
            callback,
            WriteCallback.writeCallback,
        );

        return 0;
    }

    pub fn pwrite(lua: zlj.State) !c_int {
        const f = lua.checkUserData(1, xev.File, Self.tname);
        const loop = lua.checkUserData(2, xev.Loop, Loop.tname);
        const str = lua.checkString(3);
        const offset: usize = @intCast(lua.checkLong(4));
        lua.checkValueType(5, .function); // Callback.
        lua.setTop(5);

        const callback = try WriteCallback.init(lua);
        f.pwrite(
            loop,
            try getAlloc(lua).create(xev.Completion),
            .{ .slice = str },
            offset,
            WriteCallback,
            callback,
            WriteCallback.writeCallback,
        );

        return 0;
    }

    pub fn close(lua: zlj.State) !c_int {
        const f = lua.checkUserData(1, xev.File, Self.tname);
        const loop = lua.checkUserData(2, xev.Loop, Loop.tname);
        lua.checkValueType(3, zlj.ValueType.function); // Callback.

        // Remove extra args.
        if (lua.top() > 3) lua.pop(lua.top() - 3);

        const callback = try CloseCallback.init(lua);

        f.close(
            loop,
            try getAlloc(lua).create(xev.Completion),
            CloseCallback,
            callback,
            CloseCallback.closeCallback,
        );

        return 0;
    }
};

const Buffer = struct {
    const Self = @This();
    const tname = "xev.Buffer";

    slice: []u8,
    len: usize = 0,

    pub fn new(lua: zlj.State) !c_int {
        var size = lua.optInteger(1, 4096);
        if (size < 0) size = 0;

        const self = lua.newUserData(Self);
        const alloc = (lua.allocator() orelse &std.heap.c_allocator).*;
        self.slice = try alloc.alloc(u8, @intCast(size));

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

    /// Initialize a Callback using function and buffer on top of the stack.
    pub fn init(lua: zlj.State) !*Self {
        const alloc = getAlloc(lua);
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
        c: *xev.Completion,
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
        self.alloc.destroy(c);

        return .disarm;
    }
};

const WriteCallback = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    lua: zlj.State,
    cb_ref: c_int,

    /// Initialize a Callback using function and buffer on top of the stack.
    pub fn init(lua: zlj.State) !*Self {
        const alloc = getAlloc(lua);
        const self = try alloc.create(Self);
        self.alloc = alloc;
        self.lua = lua;
        self.cb_ref = try lua.ref(zlj.Registry);
        return self;
    }

    fn deinit(self: *Self) void {
        self.lua.unref(zlj.Registry, self.cb_ref);
        self.alloc.destroy(self);
    }

    pub fn writeCallback(
        ud: ?*WriteCallback,
        _: *xev.Loop,
        c: *xev.Completion,
        _: xev.File,
        _: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = ud.?;

        self.lua.rawGeti(zlj.Registry, self.cb_ref);

        if (r) |write| {
            self.lua.pushInteger(@intCast(write));
            self.lua.call(1, 1);
        } else |err| {
            self.lua.pushInteger(0);
            self.lua.pushString(@errorName(err));
            self.lua.call(2, 1);
        }

        if (self.lua.toBoolean(-1)) return .rearm;

        self.deinit();
        self.alloc.destroy(c);

        return .disarm;
    }
};

const CloseCallback = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    lua: zlj.State,
    cb_ref: c_int,

    /// Initialize a Callback using function on top of the stack.
    pub fn init(lua: zlj.State) !*Self {
        const alloc = getAlloc(lua);
        const self = try alloc.create(Self);
        self.alloc = alloc;
        self.lua = lua;
        self.cb_ref = try lua.ref(zlj.Registry);
        return self;
    }

    fn deinit(self: *Self) void {
        self.alloc.destroy(self);
    }

    pub fn closeCallback(
        ud: ?*CloseCallback,
        _: *xev.Loop,
        c: *xev.Completion,
        _: xev.File,
        r: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud.?;
        defer self.deinit();
        defer self.alloc.destroy(c);

        self.lua.rawGeti(zlj.Registry, self.cb_ref);

        if (r) {
            self.lua.call(0, 0);
        } else |err| {
            self.lua.pushString(@errorName(err));
            self.lua.call(1, 0);
        }

        return .disarm;
    }
};
