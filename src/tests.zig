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

    state.openLibs();

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

    state.openLibs();

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

    _ = state.checkUserData(-1, xev.Loop, "xev.Loop");
    const loop = state.toUserData(-1, xev.Loop).?;
    try loop.run(.until_done);
}

test "xev.File.open" {
    var alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = alloc.deinit();

    const state = try zlj.State.init(.{ .allocator = &alloc.allocator() });
    defer state.deinit();

    state.openLibs();

    state.pushCFunction(luaxev.luaopen_xev);
    state.call(0, 0);

    try state.doString(
        \\  function test()
        \\      local xev = require("xev")
        \\      return xev.File.open(0)
        \\  end
    , null);
    state.getGlobal("test");
    state.call(0, 1);

    _ = state.checkUserData(-1, xev.File, "xev.File");
    _ = state.toUserData(-1, xev.File).?;
}

test "xev.File.read" {
    var alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = alloc.deinit();

    const state = try zlj.State.init(.{ .allocator = &alloc.allocator() });
    defer state.deinit();

    state.openLibs();

    state.pushCFunction(luaxev.luaopen_xev);
    state.call(0, 0);

    const f = try std.fs.cwd().openFile("src/testdata/file.txt", .{});
    defer f.close();

    try state.doString(
        \\  function test(fd)
        \\      local xev = require("xev")
        \\      local loop = xev.Loop.new()
        \\      local comp = xev.Completion.new()
        \\      local buf = xev.ReadBuffer.new()
        \\      local str = ""
        \\
        \\      local f = xev.File.open(fd)
        \\      f:read(loop, comp, buf, function() str = buf:tostring() end)
        \\      loop:run("until_done")
        \\
        \\      return str
        \\  end
    , null);
    state.getGlobal("test");
    state.pushAnyType(f.handle);
    state.call(1, 1);

    try testing.expectEqualStrings(
        "Hello world!\n",
        state.popAnyType([]const u8).?,
    );
}

