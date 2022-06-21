const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const stdin = std.io.getStdIn();
    const src = stdin.reader().readAllAlloc(b.allocator, std.math.maxInt(usize)) catch unreachable;
    defer b.allocator.free(src);

    const stdout = std.io.getStdOut();
    var buffered_writer = BufferedWriter { .unbuffered_writer = stdout.writer() };
    defer buffered_writer.flush() catch |err| {
        std.debug.panic("could not flush output: {}", .{err});
    };
    var writer = buffered_writer.writer();
    defer endDocument(writer);

    var bytes: []const u8 = src;

    var begun_document = false;
    var is_inside_list = false;

    while(bytes.len > 0) {
        var title: []const u8 = "";
        var maybe_background: ?[]const u8 = null;
        var maybe_header: ?[]const u8 = null;
        var maybe_footer: ?[]const u8 = null;

        is_inside_list = false;

        var lines = std.mem.split(u8, bytes, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "---")) {
                // TODO: not here
                bytes = lines.rest();
                break;
            } else if (consumePrefix(line, "background:")) |background| {
                maybe_background = std.mem.trimLeft(u8, background, " ");
            } else if (consumePrefix(line, "header:")) |header| {
                maybe_header = std.mem.trimLeft(u8, header, " ");
            } else if (consumePrefix(line, "footer:")) |footer| {
                maybe_footer = std.mem.trimLeft(u8, footer, " ");
            } else if (consumePrefix(line, "#")) |heading| {
                title = std.mem.trimLeft(u8, heading, " ");
            }
        } else {
            bytes = "";
        }

        if (!begun_document) {
            beginDocument(writer, title);
        }

        writer.writeAll("<section") catch unreachable;
        if (maybe_background) |background| {
            writer.print("style=\"background-image: url({s})\"", .{background}) catch unreachable;
        }
        writer.writeAll(">") catch unreachable;
        defer writer.writeAll("</section>") catch unreachable;

//        switch (nextByte(&line)) {
//            '#' => {
//                if (consumeByte(&line, '#')) {
//                    if (consumeByte(&line, '#')) {
//                        // speaker notes
//                    } else {
//                        // h2
//                    }
//                } else {
//                    // h1
//                }
//            }
//            '-' => {
//                // ul
//            }
//            else => {
//                // p
//            }
//        }
    }
}

const BufferedWriter = std.io.BufferedWriter(4 * 1024, std.fs.File.Writer);
const Writer = BufferedWriter.Writer;

fn peekByte(bytes: *[]const u8) ?u8 {
    if (bytes.len == 0) {
        return null;
    } else {
        return bytes[0];
    }
}

fn nextByte(bytes: *[]const u8) ?u8 {
    if (bytes.len == 0) {
        return null;
    } else {
        const b = bytes[0];
        bytes.* = bytes[1..];
        return b;
    }
}

fn consumeByte(bytes: *[]const u8, byte: u8) bool {
    if (bytes.len > 0 and bytes[0] == byte) {
        bytes.* = bytes[1..];
        return true;
    } else {
        return false;
    }
}

fn consumePrefix(bytes: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, prefix)) {
        return bytes[prefix.len..];
    } else {
        return null;
    }
}

fn beginDocument(writer: Writer, title: []const u8) void {
    const prefix =
        \\<!DOCTYPE html>
        \\<head>
        \\<meta charset="utf-8">
        \\<link rel="stylesheet" type="text/css" href="../style.css">
        \\<title>{s}</title>
        \\</head>
        \\<body>
        \\
        \\
        ;
    writer.print(prefix, .{title}) catch unreachable;
}

fn endDocument(writer: Writer) void {
    const postfix =
        \\
        \\
        \\</body>
        \\
        ;
    writer.writeAll(postfix) catch unreachable;
}

fn beginSection(writer: Writer, maybe_background: ?[]const u8, maybe_header: ?[]const u8) void {
    writer.writeAll("<section") catch unreachable;
    if (maybe_background) |background| {
        writer.print("style=\"background-image: url({s})\"", .{background}) catch unreachable;
    }
    writer.writeAll(">\n") catch unreachable;

    if (maybe_header) |header| {
        writer.writeAll("\t<header>\n") catch unreachable;
        writer.writeAll("\t\t") catch unreachable;
        writer.writeAll(header);
        writer.writeAll("\t</header>\n") catch unreachable;
    }
}

fn endSection(writer: Writer, maybe_footer: ?[]const u8) void {
    if (maybe_footer) |footer| {
        writer.writeAll("\t<footer>\n") catch unreachable;
        writer.writeAll("\t\t") catch unreachable;
        writer.writeAll(footer);
        writer.writeAll("\t</footer>\n") catch unreachable;
    }
}

