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

        const install_lib_unit_tests = b.addInstallArtifact(lib_unit_tests, .{});
        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        test_step.dependOn(&install_lib_unit_tests.step);
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
}
