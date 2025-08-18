const std = @import("std");
const testing = std.testing;

const xev = @import("libxev");
const zlj = @import("zluajit");
const luaxev = @import("luaxev");

test "luaopen_xev" {
    var alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = alloc.deinit();

    const state = try zlj.State.init(.{ .allocator = &alloc.allocator() });
    defer state.deinit();

    state.openPackage();

    state.pushCFunction(luaxev.luaopen_xev);
    state.call(0, 0);

    state.getGlobal("xev");
    const xev_tab = state.toAnyType(zlj.TableRef, -1).?;
    const loop = xev_tab.get("Loop", zlj.TableRef).?;
    try testing.expect(loop.get("init", zlj.FunctionRef) != null);
}

test "xev.Loop.new" {
    var alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = alloc.deinit();

    const state = try zlj.State.init(.{ .allocator = &alloc.allocator() });
    defer state.deinit();

    state.openPackage();

    state.pushCFunction(luaxev.luaopen_xev);
    state.call(0, 0);

    try state.doString(
        \\  function test()
        \\      local xev = require("xev")
        \\      return xev.Loop.new()
        \\  end
    , null);
    state.getGlobal("test");
    state.call(0, 1);

    var loop = &state.checkUserData(-1, luaxev.Loop).loop;
    try loop.run(.until_done);
}

test "xev.File.open/close" {
    var alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = alloc.deinit();

    const state = try zlj.State.init(.{ .allocator = &alloc.allocator() });
    defer state.deinit();

    state.openPackage();
    state.openBase();

    const f = try std.fs.cwd().openFile("src/testdata/file.txt", .{});

    state.pushCFunction(luaxev.luaopen_xev);
    state.call(0, 0);

    try state.doString(
        \\  function test(fd)
        \\      local xev = require("xev")
        \\      local loop = xev.Loop.new()
        \\
        \\      local f = xev.File.open(fd)
        \\      local closed = false
        \\      f:close(loop, function() closed = true end)
        \\
        \\      loop:run("no_wait")
        \\
        \\      return closed, f
        \\  end
    , null);
    state.getGlobal("test");
    state.pushAnyType(f.handle);
    state.pCall(1, 2, 0) catch {
        state.dumpStack();
        @panic("err");
    };

    _ = state.checkUserData(-1, luaxev.File);

    const closed = state.toBoolean(-2);
    try testing.expect(closed);
}

test "xev.File.read/pread" {
    var alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = alloc.deinit();

    const state = try zlj.State.init(.{ .allocator = &alloc.allocator() });
    defer state.deinit();

    state.openPackage();

    state.pushCFunction(luaxev.luaopen_xev);
    state.call(0, 0);

    const f = try std.fs.cwd().openFile("src/testdata/file.txt", .{});
    defer f.close();

    try state.doString(
        \\  function test(fd)
        \\      local xev = require("xev")
        \\      local loop = xev.Loop.new()
        \\      local buf1 = xev.Buffer.new()
        \\      local buf2 = xev.Buffer.new()
        \\      local read_str = ""
        \\      local pread_str = ""
        \\
        \\      local f = xev.File.open(fd)
        \\      f:read(loop, buf1, function() read_str = buf1:tostring() end)
        \\      f:pread(loop, buf2, 6, function() pread_str = buf2:tostring() end)
        \\      loop:run("until_done")
        \\
        \\      return read_str, pread_str
        \\  end
    , null);
    state.getGlobal("test");
    state.pushAnyType(f.handle);
    state.call(1, 2);

    try testing.expectEqualStrings(
        "world!\n",
        state.popAnyType([]const u8).?,
    );
    try testing.expectEqualStrings(
        "Hello world!\n",
        state.popAnyType([]const u8).?,
    );
}

test "xev.File.write/prwrite" {
    var alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = alloc.deinit();

    const state = try zlj.State.init(.{ .allocator = &alloc.allocator() });
    defer state.deinit();

    state.openPackage();

    state.pushCFunction(luaxev.luaopen_xev);
    state.call(0, 0);

    const f = try std.fs.cwd().createFile(
        "src/testdata/tmp.txt",
        .{ .read = true, .truncate = true },
    );
    defer f.close();
    defer _ = std.fs.cwd().deleteFile("src/testdata/tmp.txt") catch unreachable;

    try state.doString(
        \\  function test(fd)
        \\      local xev = require("xev")
        \\      local loop = xev.Loop.new()
        \\      local write = false
        \\      local pwrite = false
        \\
        \\      local f = xev.File.open(fd)
        \\      f:write(loop, "hello from lua!", function() write = true end)
        \\      loop:run("until_done")
        \\
        \\      f:pwrite(loop, "earth", 11, function() pwrite = true end)
        \\      loop:run("until_done")
        \\
        \\      return write, pwrite
        \\  end
    , null);
    state.getGlobal("test");
    state.pushAnyType(f.handle);
    state.call(1, 2);

    try testing.expect(state.toBoolean(-2));
    try testing.expect(state.toBoolean(-1));

    try f.seekTo(0);

    var buf: [1024]u8 = undefined;
    const read = try f.read(buf[0..]);

    try testing.expectEqualStrings("hello from earth", buf[0..read]);
}

test "xev.File.queueWrite/queuePWrite" {
    var alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = alloc.deinit();

    const state = try zlj.State.init(.{ .allocator = &alloc.allocator() });
    defer state.deinit();

    state.openPackage();

    state.pushCFunction(luaxev.luaopen_xev);
    state.call(0, 0);

    const f = try std.fs.cwd().createFile(
        "src/testdata/tmp.txt",
        .{ .read = true, .truncate = true },
    );
    defer f.close();
    defer _ = std.fs.cwd().deleteFile("src/testdata/tmp.txt") catch unreachable;

    try state.doString(
        \\  function test(fd)
        \\      local xev = require("xev")
        \\      local loop = xev.Loop.new()
        \\      local wqueue = xev.WriteQueue.new()
        \\      local qwrite = false
        \\      local qpwrite = false
        \\
        \\      local f = xev.File.open(fd)
        \\      f:queueWrite(loop, wqueue, "hello from lua!", function() qwrite = true end)
        \\      f:queuePWrite(loop, wqueue, "earth", 11, function() qpwrite = true end)
        \\      loop:run("until_done")
        \\
        \\      return qwrite, qpwrite
        \\  end
    , null);
    state.getGlobal("test");
    state.pushAnyType(f.handle);
    state.call(1, 2);

    try testing.expect(state.toBoolean(-2));
    try testing.expect(state.toBoolean(-1));

    try f.seekTo(0);

    var buf: [1024]u8 = undefined;
    const read = try f.read(buf[0..]);

    try testing.expectEqualStrings("hello from earth", buf[0..read]);
}
