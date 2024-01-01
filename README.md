# zig-wayland

Zig 0.12 bindings and protocol scanner for libwayland.

## Usage

### build.zig.zon

```
.zig_wayland = .{
    .url = "https://github.com/sammyjames/zig-wayland/archive/<commit>.tar.gz",
    .hash = "<hash>",
},
```

### build.zig

```zig
const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigwl_dep = b.dependency("zig_wayland", .{ .protocols_system = @as([]const []const u8, &.{
        "stable/xdg-shell/xdg-shell.xml",
        "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
    }), .generate = @as([]const []const u8, &.{
        "wl_compositor:1",
        "wl_shm:1",
        "wl_seat:1",
        "wl_output:1",
        "xdg_wm_base:1",
        "zxdg_decoration_manager_v1:1",
    }) });
    const zigwl_lib = zigwl_dep.artifact("libzig-wayland");
    const zigwl_bindings = zigwl_dep.module("zig-wayland");

    const exe = b.addExecutable(.{
        .name = "foobar",
        .root_source_file = .{ .path = "foobar.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("wayland", zigwl_bindings);
    exe.linkLibC();
    exe.linkLibrary(zigwl_lib);

    b.installArtifact(exe);
}
```

Then, you may import the provided module in your project:

```zig
const wayland = @import("wayland");
const wl = wayland.client.wl;
```

Note that zig-wayland does not currently do extensive verification of Wayland
protocol xml or provide good error messages if protocol xml is invalid. It is
recommend to use `wayland-scanner --strict` to debug protocol xml instead.

## License

zig-wayland is released under the MIT (expat) license.
