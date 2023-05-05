const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const ascii = std.ascii;

const catalog_txt = @embedFile("crc/catalog.txt");

pub fn main() anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len <= 1) {
        usageAndExit(std.io.getStdErr(), args[0], 1);
    }

    const zig_src_root = args[1];
    if (mem.startsWith(u8, zig_src_root, "-")) {
        usageAndExit(std.io.getStdErr(), args[0], 1);
    }

    var zig_src_dir = try fs.cwd().openDir(zig_src_root, .{});
    defer zig_src_dir.close();

    const target_sub_path = try fs.path.join(arena, &.{ "lib", "std", "hash", "crc" });
    var target_dir = try zig_src_dir.makeOpenPath(target_sub_path, .{});
    defer target_dir.close();

    var zig_code_file = try target_dir.createFile("catalog.zig", .{});
    defer zig_code_file.close();

    var cbw = std.io.bufferedWriter(zig_code_file.writer());
    defer cbw.flush() catch unreachable;
    const code_writer = cbw.writer();

    try code_writer.writeAll(
        \\//! This file is auto-generated by tools/update_crc_catalog.zig.
        \\
        \\const Crc = @import("../crc.zig").Crc;
        \\
        \\test {
        \\    _ = @import("catalog_test.zig");
        \\}
        \\
    );

    var zig_test_file = try target_dir.createFile("catalog_test.zig", .{});
    defer zig_test_file.close();

    var tbw = std.io.bufferedWriter(zig_test_file.writer());
    defer tbw.flush() catch unreachable;
    const test_writer = tbw.writer();

    try test_writer.writeAll(
        \\//! This file is auto-generated by tools/update_crc_catalog.zig.
        \\
        \\const std = @import("../../std.zig");
        \\const testing = std.testing;
        \\const catalog = @import("catalog.zig");
        \\
    );

    var stream = std.io.fixedBufferStream(catalog_txt);
    const reader = stream.reader();

    while (try reader.readUntilDelimiterOrEofAlloc(arena, '\n', std.math.maxInt(usize))) |line| {
        if (line.len == 0 or line[0] == '#')
            continue;

        var width: []const u8 = undefined;
        var poly: []const u8 = undefined;
        var init: []const u8 = undefined;
        var refin: []const u8 = undefined;
        var refout: []const u8 = undefined;
        var xorout: []const u8 = undefined;
        var check: []const u8 = undefined;
        var residue: []const u8 = undefined;
        var name: []const u8 = undefined;

        var it = mem.splitFull(u8, line, "  ");
        while (it.next()) |property| {
            const i = mem.indexOf(u8, property, "=").?;
            const key = property[0..i];
            const value = property[i + 1 ..];
            if (mem.eql(u8, key, "width")) {
                width = value;
            } else if (mem.eql(u8, key, "poly")) {
                poly = value;
            } else if (mem.eql(u8, key, "init")) {
                init = value;
            } else if (mem.eql(u8, key, "refin")) {
                refin = value;
            } else if (mem.eql(u8, key, "refout")) {
                refout = value;
            } else if (mem.eql(u8, key, "xorout")) {
                xorout = value;
            } else if (mem.eql(u8, key, "check")) {
                check = value;
            } else if (mem.eql(u8, key, "residue")) {
                residue = value;
            } else if (mem.eql(u8, key, "name")) {
                name = mem.trim(u8, value, "\"");
            } else {
                unreachable;
            }
        }

        const snakecase = try ascii.allocLowerString(arena, name);
        defer arena.free(snakecase);

        _ = mem.replace(u8, snakecase, "-", "_", snakecase);
        _ = mem.replace(u8, snakecase, "/", "_", snakecase);

        var buf = try std.ArrayList(u8).initCapacity(arena, snakecase.len);
        defer buf.deinit();

        var prev: u8 = 0;
        for (snakecase, 0..) |c, i| {
            if (c == '_') {
                // do nothing
            } else if (i == 0) {
                buf.appendAssumeCapacity(ascii.toUpper(c));
            } else if (prev == '_') {
                buf.appendAssumeCapacity(ascii.toUpper(c));
            } else {
                buf.appendAssumeCapacity(c);
            }
            prev = c;
        }

        const camelcase = buf.items;

        try code_writer.writeAll(try std.fmt.allocPrint(arena,
            \\
            \\pub const {s} = Crc(u{s}, .{{
            \\    .polynomial = {s},
            \\    .initial = {s},
            \\    .reflect_input = {s},
            \\    .reflect_output = {s},
            \\    .xor_output = {s},
            \\}});
            \\
        , .{ camelcase, width, poly, init, refin, refout, xorout }));

        try test_writer.writeAll(try std.fmt.allocPrint(arena,
            \\
            \\test "{0s}" {{
            \\    const {1s} = catalog.{1s};
            \\
            \\    try testing.expectEqual(@as(u{2s}, {3s}), {1s}.hash("123456789"));
            \\
            \\    var c = {1s}.init();
            \\    c.update("1234");
            \\    c.update("56789");
            \\    try testing.expectEqual(@as(u{2s}, {3s}), c.final());
            \\}}
            \\
        , .{ name, camelcase, width, check }));
    }
}

fn usageAndExit(file: fs.File, arg0: []const u8, code: u8) noreturn {
    file.writer().print(
        \\Usage: {s} /path/git/zig
        \\
    , .{arg0}) catch std.process.exit(1);
    std.process.exit(code);
}
