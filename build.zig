const std = @import("std");
const Build = std.Build;
const fs = std.fs;
const mem = std.mem;

pub fn build(b: *Build) void {
    const system_protocols = b.option(
        []const []const u8,
        "protocols_system",
        "the system protocols to generate",
    );
    const custom_protocols = b.option(
        []const []const u8,
        "protocols_custom",
        "the custom protocols to generate",
    );
    const to_generate = b.option(
        []const []const u8,
        "generate",
        "protocols to generate in the format of {name}:{version}",
    );

    const target = b.standardTargetOptions(.{});

    const scanner = Scanner.create(b, .{ .target = target });

    if (system_protocols) |sys_protos| {
        for (sys_protos) |proto| {
            scanner.addSystemProtocol(proto);
        }
    }

    if (custom_protocols) |custom_protos| {
        for (custom_protos) |proto| {
            scanner.addCustomProtocol(proto);
        }
    }

    if (to_generate) |generate_me| {
        for (generate_me) |gen| {
            var it = std.mem.splitScalar(u8, gen, ':');
            scanner.generate(it.first(), std.fmt.parseInt(u32, it.next() orelse "1", 10) catch 1);
        }
    }

    var wayland = b.addModule("zig-wayland", .{
        .root_source_file = scanner.result,
        .link_libc = true,
        .target = target,
    });

    wayland.linkSystemLibrary("wayland-client", .{});
    wayland.linkSystemLibrary("wayland-server", .{});

    scanner.addCSource(wayland);
}

pub const Scanner = struct {
    run: *Build.Step.Run,
    result: Build.LazyPath,

    /// Path to the system protocol directory, stored to avoid invoking pkg-config N times.
    wayland_protocols_path: []const u8,

    // TODO remove these when the workaround for zig issue #131 is no longer needed.
    modules: std.ArrayListUnmanaged(*Build.Module) = .{},
    c_sources: std.ArrayListUnmanaged(Build.LazyPath) = .{},

    pub const Options = struct {
        /// Path to the wayland.xml file.
        /// If null, the output of `pkg-config --variable=pkgdatadir wayland-scanner` will be used.
        wayland_xml_path: ?[]const u8 = null,
        /// Path to the wayland-protocols installation.
        /// If null, the output of `pkg-config --variable=pkgdatadir wayland-protocols` will be used.
        wayland_protocols_path: ?[]const u8 = null,

        target: Build.ResolvedTarget,
    };

    pub fn create(b: *Build, options: Options) *Scanner {
        const wayland_xml_path = options.wayland_xml_path orelse blk: {
            const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-scanner" });
            break :blk b.pathJoin(&.{ mem.trim(u8, pc_output, &std.ascii.whitespace), "wayland.xml" });
        };
        const wayland_protocols_path = options.wayland_protocols_path orelse blk: {
            const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" });
            break :blk mem.trim(u8, pc_output, &std.ascii.whitespace);
        };

        const exe = b.addExecutable(.{
            .name = "zig-wayland-scanner",
            .target = options.target,
            .root_source_file = b.path("src/scanner.zig"),
        });

        const run = b.addRunArtifact(exe);

        run.addArg("-o");
        const result = run.addOutputFileArg("wayland.zig");

        run.addArg("-i");
        run.addFileArg(.{ .cwd_relative = wayland_xml_path });

        const scanner = b.allocator.create(Scanner) catch @panic("OOM");
        scanner.* = .{
            .run = run,
            .result = result,
            .wayland_protocols_path = wayland_protocols_path,
        };

        return scanner;
    }

    /// Scan protocol xml provided by the wayland-protocols package at the given path
    /// relative to the wayland-protocols installation. (e.g. "stable/xdg-shell/xdg-shell.xml")
    pub fn addSystemProtocol(scanner: *Scanner, relative_path: []const u8) void {
        const b = scanner.run.step.owner;
        const full_path = b.pathJoin(&.{ scanner.wayland_protocols_path, relative_path });

        scanner.run.addArg("-i");
        scanner.run.addFileArg(.{ .cwd_relative = full_path });

        scanner.generateCSource(full_path);
    }

    /// Scan the protocol xml at the given path.
    pub fn addCustomProtocol(scanner: *Scanner, path: []const u8) void {
        scanner.run.addArg("-i");
        scanner.run.addFileArg(.{ .cwd_relative = path });

        scanner.generateCSource(path);
    }

    /// Generate code for the given global interface at the given version,
    /// as well as all interfaces that can be created using it at that version.
    /// If the version found in the protocol xml is less than the requested version,
    /// an error will be printed and code generation will fail.
    /// Code is always generated for wl_display, wl_registry, wl_callback, and wl_buffer.
    pub fn generate(scanner: *Scanner, global_interface: []const u8, version: u32) void {
        var buffer: [32]u8 = undefined;
        const version_str = std.fmt.bufPrint(&buffer, "{}", .{version}) catch unreachable;

        scanner.run.addArgs(&.{ "-g", global_interface, version_str });
    }

    /// Generate and add the necessary C source to the compilation unit.
    /// Once https://github.com/ziglang/zig/issues/131 is resolved we can remove this.
    pub fn addCSource(scanner: *Scanner, module: *Build.Module) void {
        const b = scanner.run.step.owner;

        for (scanner.c_sources.items) |c_source| {
            module.addCSourceFile(.{
                .file = c_source,
                .flags = &.{ "-std=c99", "-O2" },
            });
        }

        scanner.modules.append(b.allocator, module) catch @panic("OOM");
    }

    /// Once https://github.com/ziglang/zig/issues/131 is resolved we can remove this.
    fn generateCSource(scanner: *Scanner, protocol: []const u8) void {
        const b = scanner.run.step.owner;
        const cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code", protocol });

        const out_name = mem.concat(b.allocator, u8, &.{ fs.path.stem(protocol), "-protocol.c" }) catch @panic("OOM");

        const c_source = cmd.addOutputFileArg(out_name);

        for (scanner.modules.items) |module| {
            module.addCSourceFile(.{
                .file = c_source,
                .flags = &.{ "-std=c99", "-O2" },
            });
        }

        scanner.c_sources.append(b.allocator, c_source) catch @panic("OOM");
    }
};
