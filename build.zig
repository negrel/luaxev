const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const libxev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const zluajit = b.dependency("zluajit", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.addModule("luaxev", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("libxev", libxev.module("xev"));
    lib_mod.addImport("zluajit", zluajit.module("zluajit"));

    const lib = b.addSharedLibrary(.{
        .name = "luaxev",
        .root_module = lib_mod,
    });
    {

        // This declares intent for the library to be installed into the standard
        // location when the user invokes the "install" step (the default step when
        // running `zig build`).
        b.installArtifact(lib);
    }

    // Generate documentation.
    {
        const install_docs = b.addInstallDirectory(.{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        const docs_step = b.step("docs", "Install docs into zig-out/docs");
        docs_step.dependOn(&install_docs.step);
    }

    // Unit tests.
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    {
        lib_unit_tests.root_module.addImport(
            "zluajit",
            zluajit.module("zluajit"),
        );
        lib_unit_tests.root_module.addImport("luaxev", lib_mod);
        lib_unit_tests.root_module.addImport("libxev", libxev.module("xev"));

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
    }

    // Unit tests with valgrind.
    {
        const valgrind_tests = b.addSystemCommand(&[_][]const u8{
            "valgrind",
            "--leak-check=full",
            "--track-origins=yes",
            "--error-exitcode=1",
        });
        valgrind_tests.addArtifactArg(lib_unit_tests);

        const valgrind_test_step = b.step("test-valgrind", "Run unit tests with valgrind");
        valgrind_test_step.dependOn(&valgrind_tests.step);
    }

    // We will also create a module for our other entry point, 'main.zig'.
    // const exe_mod = b.createModule(.{
    //     .root_source_file = b.path("src/main.zig"),
    //     .target = target,
    //     .optimize = optimize,
    //     .link_libc = true,
    // });
    // exe_mod.linkSystemLibrary("luajit", .{ .preferred_link_mode = .static, .needed = true });

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    // const exe = b.addExecutable(.{
    //     .name = "luaxev",
    //     .root_module = exe_mod,
    // });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    // b.installArtifact(exe);
    // exe_mod.addImport("xev", dep.module("xev"));

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    // const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    // run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    // const run_step = b.step("run", "Run the app");
    // run_step.dependOn(&run_cmd.step);

    // const exe_unit_tests = b.addTest(.{
    //     .root_module = exe_mod,
    // });

    // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_exe_unit_tests.step);
}
