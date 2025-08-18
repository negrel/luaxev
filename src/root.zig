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

    // Buffer.
    {
        lua.newTable();
        const read_buffer = lua.toAnyType(zlj.TableRef, -1).?;
        mod.set("Buffer", read_buffer);
        read_buffer.set("new", Buffer.new);
    }

    // WriteQueue.
    {
        lua.newTable();
        const writeQueue = lua.toAnyType(zlj.TableRef, -1).?;
        mod.set("WriteQueue", writeQueue);
        writeQueue.set("new", WriteQueue.new);
    }

    return 0;
}

fn getAlloc(lua: zlj.State) std.mem.Allocator {
    return (lua.allocator() orelse &std.heap.c_allocator).*;
}

pub const Loop = struct {
    const Self = @This();
    pub const zluajitTName = "xev.Loop";

    loop: xev.Loop,

    fn new(lua: zlj.State) !c_int {
        const self = lua.newUserData(Self);

        if (lua.newMetaTable(Self)) {
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
        lua.setMetaTable(-2);

        self.loop = try xev.Loop.init(.{});

        return 1;
    }

    fn run(lua: zlj.State) !c_int {
        var loop = &lua.checkUserData(1, Self).loop;
        const mode = lua.checkEnum(2, xev.RunMode, null);

        try loop.run(mode);

        return 0;
    }
};

pub const File = struct {
    const Self = @This();
    pub const zluajitTName = "xev.File";

    file: xev.File,

    fn open(lua: zlj.State) c_int {
        const fd = lua.checkAnyType(1, std.fs.File.Handle);

        const self = lua.newUserData(Self);

        if (lua.newMetaTable(Self)) {
            const mt = lua.toAnyType(zlj.TableRef, -1).?;

            // Meta methods.
            {
                mt.set("__gc", Self.deinit);
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
                index.set("queueWrite", Self.queueWrite);
                index.set("pwrite", Self.pwrite);
                index.set("queuePWrite", Self.queuePWrite);
                index.set("close", Self.close);
                mt.set("__index", index);
            }
        }
        lua.setMetaTable(-2);

        self.file = xev.File.initFd(fd);

        return 1;
    }

    fn deinit(self: *const Self) void {
        self.file.deinit();
    }

    fn read(lua: zlj.State) !c_int {
        const f = &lua.checkUserData(1, Self).file;
        const loop = &lua.checkUserData(2, Loop).loop;
        const buf = lua.checkUserData(3, Buffer);
        lua.checkValueType(4, .function); // Callback.
        lua.setTop(4);

        const callback = try ReadCallback.init(lua, .{
            .lua_callback = try lua.refValue(zlj.Registry, 4),
            .lua_buffer = try lua.refValue(zlj.Registry, 3),
        });

        f.read(
            loop,
            &callback.completion,
            .{ .slice = buf.slice },
            ReadCallback,
            callback,
            ReadCallback.read,
        );

        return 0;
    }

    fn pread(lua: zlj.State) !c_int {
        const f = &lua.checkUserData(1, Self).file;
        const loop = &lua.checkUserData(2, Loop).loop;
        const buf = lua.checkUserData(3, Buffer);
        const offset: usize = @intCast(lua.checkLong(4));
        lua.checkValueType(5, .function); // Callback.
        lua.setTop(5);

        const callback = try ReadCallback.init(lua, .{
            .lua_callback = try lua.refValue(zlj.Registry, 5),
            .lua_buffer = try lua.refValue(zlj.Registry, 3),
        });

        f.pread(
            loop,
            &callback.completion,
            .{ .slice = buf.slice },
            offset,
            ReadCallback,
            callback,
            ReadCallback.read,
        );

        return 0;
    }

    fn write(lua: zlj.State) !c_int {
        const f = &lua.checkUserData(1, Self).file;
        const loop = &lua.checkUserData(2, Loop).loop;
        const buf = Buffer.fromLuaArg(lua, 3);
        lua.checkValueType(4, .function); // Callback.
        lua.setTop(4);

        const callback = try WriteCallback.init(lua, .{
            .lua_callback = try lua.refValue(zlj.Registry, 4),
            .lua_buffer = try lua.refValue(zlj.Registry, 3),
        });

        f.write(
            loop,
            &callback.completion,
            .{ .slice = buf },
            WriteCallback,
            callback,
            WriteCallback.write,
        );

        return 0;
    }

    fn queueWrite(lua: zlj.State) !c_int {
        const f = &lua.checkUserData(1, Self).file;
        const loop = &lua.checkUserData(2, Loop).loop;
        const q = &lua.checkUserData(3, WriteQueue).wqueue;
        const buf = Buffer.fromLuaArg(lua, 4);
        lua.checkValueType(5, .function); // Callback.
        lua.setTop(5);

        const req = try getAlloc(lua).create(xev.WriteRequest);
        const callback = try QWriteCallback.init(lua, .{
            .lua_callback = try lua.refValue(zlj.Registry, 5),
            .lua_buffer = try lua.refValue(zlj.Registry, 4),
            .write_request = req,
        });

        f.queueWrite(
            loop,
            q,
            req,
            .{ .slice = buf },
            QWriteCallback,
            callback,
            QWriteCallback.write,
        );

        return 0;
    }

    fn pwrite(lua: zlj.State) !c_int {
        const f = lua.checkUserData(1, Self).file;
        const loop = &lua.checkUserData(2, Loop).loop;
        const buf = Buffer.fromLuaArg(lua, 3);
        const offset: usize = @intCast(lua.checkLong(4));
        lua.checkValueType(5, .function); // Callback.
        lua.setTop(5);

        const callback = try WriteCallback.init(lua, .{
            .lua_callback = try lua.refValue(zlj.Registry, 5),
            .lua_buffer = try lua.refValue(zlj.Registry, 3),
        });

        f.pwrite(
            loop,
            &callback.completion,
            .{ .slice = buf },
            offset,
            WriteCallback,
            callback,
            WriteCallback.write,
        );

        return 0;
    }

    fn queuePWrite(lua: zlj.State) !c_int {
        const f = lua.checkUserData(1, Self).file;
        const loop = &lua.checkUserData(2, Loop).loop;
        const q = &lua.checkUserData(3, WriteQueue).wqueue;
        const buf = Buffer.fromLuaArg(lua, 4);
        const offset: usize = @intCast(lua.checkLong(5));
        lua.checkValueType(6, .function); // Callback.
        lua.setTop(6);

        const req = try getAlloc(lua).create(xev.WriteRequest);
        const callback = try QWriteCallback.init(lua, .{
            .lua_callback = try lua.refValue(zlj.Registry, 6),
            .lua_buffer = try lua.refValue(zlj.Registry, 4),
            .write_request = req,
        });

        f.queuePWrite(
            loop,
            q,
            req,
            .{ .slice = buf },
            offset,
            QWriteCallback,
            callback,
            QWriteCallback.write,
        );

        return 0;
    }

    fn close(lua: zlj.State) !c_int {
        const f = &lua.checkUserData(1, Self).file;
        const loop = &lua.checkUserData(2, Loop).loop;
        lua.checkValueType(3, zlj.ValueType.function); // Callback.
        lua.setTop(3);

        const callback = try CloseCallback.init(lua, .{
            .lua_callback = try lua.refValue(zlj.Registry, 3),
        });

        f.close(
            loop,
            &callback.completion,
            CloseCallback,
            callback,
            CloseCallback.close,
        );

        return 0;
    }
};

pub const Buffer = struct {
    const Self = @This();
    pub const zluajitTName = "xev.Buffer";

    slice: []u8,
    len: usize = 0,

    fn new(lua: zlj.State) !c_int {
        var size: usize = 4096;
        var str: []const u8 = "";

        if (!lua.isNoneOrNil(1)) {
            const vtype = lua.valueType(1);
            if (vtype != .string and vtype != .number)
                return lua.argError(1, "expected string or number");
            if (vtype == .string) {
                str = lua.toString(1).?;
                size = str.len;
            } else {
                size = @intCast(lua.toInteger(1));
            }

            size = @max(
                size,
                @as(usize, @intCast(lua.optInteger(2, -1))),
            );
        }

        const self = lua.newUserData(Self);
        const alloc = (lua.allocator() orelse &std.heap.c_allocator).*;
        self.slice = try alloc.alloc(u8, @intCast(size));
        std.mem.copyForwards(u8, self.slice, str);

        if (lua.newMetaTable(Self)) {
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
        lua.setMetaTable(-2);

        return 1;
    }

    fn fromLuaArg(lua: zlj.State, narg: c_int) []const u8 {
        const vtype = lua.valueType(narg);
        if (vtype != .string and vtype != .userdata)
            _ = lua.argError(narg, "string or xev.Buffer expected");

        if (vtype == .string) return lua.toString(narg).?;

        const self = lua.checkUserData(narg, Self);
        return self.slice;
    }

    fn gc(lua: zlj.State) c_int {
        const self = lua.checkUserData(1, Self);
        const alloc = (lua.allocator() orelse &std.heap.c_allocator).*;
        alloc.free(self.slice);
        return 0;
    }

    fn toString(lua: zlj.State) c_int {
        const self = lua.checkUserData(1, Self);
        lua.pushString(self.slice[0..self.len]);
        return 1;
    }
};

pub const WriteQueue = struct {
    const Self = @This();
    pub const zluajitTName = "xev.WriteQueue";

    wqueue: xev.WriteQueue,

    fn new(lua: zlj.State) !c_int {
        const self = lua.newUserData(Self);

        if (lua.newMetaTable(Self)) {
            const mt = lua.toAnyType(zlj.TableRef, -1).?;

            // Meta methods.
            {
                mt.set("__gc", false);
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
        lua.setMetaTable(-2);

        self.wqueue.head = null;
        self.wqueue.tail = null;

        return 1;
    }
};

fn Callback(Data: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        lua: zlj.State,
        completion: xev.Completion,
        data: Data,

        fn init(lua: zlj.State, data: Data) !*Self {
            const alloc = getAlloc(lua);
            const self = try alloc.create(Self);
            self.alloc = alloc;
            self.lua = lua;
            self.data = data;

            return self;
        }

        fn deinit(self: *Self) void {
            self.data.deinit(self.lua);
            self.alloc.destroy(self);
        }

        fn read(
            ud: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.File,
            _: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const self = ud.?;
            defer self.deinit();

            self.lua.rawGeti(zlj.Registry, self.data.lua_callback);

            if (r) |bRead| {
                self.lua.rawGeti(zlj.Registry, self.data.lua_buffer);
                const buf = self.lua.popAnyType(*Buffer).?;
                buf.len = bRead;
                self.lua.pushInteger(@intCast(bRead));
                self.lua.call(1, 1);
            } else |err| {
                self.lua.pushInteger(0);
                self.lua.pushString(@errorName(err));
                self.lua.call(2, 1);
            }

            if (self.lua.toBoolean(-1)) return .rearm;

            return .disarm;
        }

        fn write(
            ud: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.File,
            _: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            const self = ud.?;
            defer self.deinit();

            if (@hasField(Self, "write_request")) {
                defer self.alloc.destroy(@field(self, "write_request"));
            }

            self.lua.rawGeti(zlj.Registry, self.data.lua_callback);

            if (r) |bWrite| {
                self.lua.pushInteger(@intCast(bWrite));
                self.lua.call(1, 1);
            } else |err| {
                self.lua.pushInteger(0);
                self.lua.pushString(@errorName(err));
                self.lua.call(2, 1);
            }

            if (self.lua.toBoolean(-1)) return .rearm;

            return .disarm;
        }

        fn close(
            ud: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.File,
            r: xev.CloseError!void,
        ) xev.CallbackAction {
            const self = ud.?;
            defer self.deinit();

            self.lua.rawGeti(zlj.Registry, self.data.lua_callback);

            if (r) {
                self.lua.call(0, 0);
            } else |err| {
                self.lua.pushString(@errorName(err));
                self.lua.call(1, 0);
            }

            return .disarm;
        }
    };
}

const ReadCallback = Callback(struct {
    const Self = @This();

    lua_callback: c_int,
    lua_buffer: c_int,

    fn deinit(self: Self, lua: zlj.State) void {
        lua.unref(zlj.Registry, self.lua_callback);
        lua.unref(zlj.Registry, self.lua_buffer);
    }
});

const WriteCallback = Callback(struct {
    const Self = @This();

    lua_callback: c_int,
    lua_buffer: c_int,

    fn deinit(self: Self, lua: zlj.State) void {
        lua.unref(zlj.Registry, self.lua_callback);
        lua.unref(zlj.Registry, self.lua_buffer);
    }
});

const QWriteCallback = Callback(struct {
    const Self = @This();

    lua_callback: c_int,
    lua_buffer: c_int,
    write_request: *xev.WriteRequest,

    fn deinit(self: Self, lua: zlj.State) void {
        lua.unref(zlj.Registry, self.lua_callback);
        lua.unref(zlj.Registry, self.lua_buffer);
        getAlloc(lua).destroy(self.write_request);
    }
});

const CloseCallback = Callback(struct {
    const Self = @This();

    lua_callback: c_int,

    fn deinit(self: Self, lua: zlj.State) void {
        lua.unref(zlj.Registry, self.lua_callback);
    }
});
