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

    var begun_document = false;

    var slide_srcs = std.mem.split(u8, src, "\n---\n");
    while(slide_srcs.next()) |slide_src| {
        var title: []const u8 = "";
        var maybe_background: ?[]const u8 = null;

        var header_count: u32 = 0;
        var headers: [32][]const u8 = undefined;
        var footer_count: u32 = 0;
        var footers: [32][]const u8 = undefined;

        const data_len = std.mem.indexOf(u8, slide_src, "\n###") orelse slide_src.len;
        const data = slide_src[0..data_len];

        var first_metadata_offset: ?usize = null;

        var data_lines = std.mem.split(u8, data, "\n");
        while (data_lines.next()) |line| {
            var is_metadata_line = false;

            if (consumePrefix(line, "background:")) |background| {
                maybe_background = std.mem.trim(u8, background, " ");
                is_metadata_line = true;
            } else if (consumePrefix(line, "header:")) |header| {
                if (header_count < headers.len) {
                    headers[header_count] = std.mem.trim(u8, header, " ");
                    header_count += 1;
                }
                is_metadata_line = true;
            } else if (consumePrefix(line, "footer:")) |footer| {
                if (footer_count < footers.len) {
                    footers[footer_count] = std.mem.trim(u8, footer, " ");
                    footer_count += 1;
                }
                is_metadata_line = true;
            } else if (consumePrefix(line, "#")) |heading| {
                title = std.mem.trim(u8, heading, " ");
            }

            if (is_metadata_line and first_metadata_offset == null) {
                first_metadata_offset = @ptrToInt(line.ptr) - @ptrToInt(data.ptr);
            }
        }

        if (!begun_document) {
            begun_document = true;
            beginDocument(writer, title);
        }

        beginSection(writer, maybe_background);
        defer endSection(writer, headers[0..header_count], footers[0..footer_count]);

        const content_len = first_metadata_offset orelse data.len;
        const content = data[0..content_len];

        var was_inside_list = false;
        var content_lines = std.mem.split(u8, content, "\n");
        while (content_lines.next()) |line| {
            var is_inside_list = false;

            if (consumePrefix(line, "#")) |heading| {
                if (consumePrefix(heading, "#")) |heading2| {
                    beginTag(writer, "h2");
                    writeLineContent(writer, heading2);
                    endTag(writer, "h2");
                } else {
                    beginTag(writer, "h1");
                    writeLineContent(writer, heading);
                    endTag(writer, "h1");
                }
            } else if (consumePrefix(line, "-")) |list_entry| {
                is_inside_list = true;
                if (!was_inside_list) {
                    beginListing(writer);
                }

                beginTag(writer, "li");
                writeLineContent(writer, list_entry);
                endTag(writer, "li");
            } else if (consumePrefix(line, "!")) |image_src| {
                writeImageTag(writer, image_src);
            } else if (consumePrefix(line, "")) |paragraph| {
                beginTag(writer, "p");
                writeLineContent(writer, paragraph);
                endTag(writer, "p");
            }

            if (was_inside_list and !is_inside_list) {
                endListing(writer);
            }
            was_inside_list = is_inside_list;
        }
        if (was_inside_list) {
            endListing(writer);
        }
    }
}

const BufferedWriter = std.io.BufferedWriter(4 * 1024, std.fs.File.Writer);
const Writer = BufferedWriter.Writer;

fn consumePrefix(bytes: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, prefix)) {
        const rest = bytes[prefix.len..];
        const trimmed = std.mem.trim(u8, rest, " ");
        return if (trimmed.len > 0) trimmed else null;
    } else {
        return null;
    }
}

fn beginDocument(writer: Writer, title: []const u8) void {
    const prefix =
        \\<!DOCTYPE html>
        \\<html>
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
        \\</body>
        \\</html>
        \\
        ;
    writer.writeAll(postfix) catch unreachable;
}

const indentation = " " ** 4;

fn beginSection(writer: Writer, maybe_background: ?[]const u8) void {
    writer.writeAll("<section") catch unreachable;
    if (maybe_background) |background| {
        if (std.mem.eql(u8, background, "main")) {
            writer.writeAll(" class=\"main\"") catch unreachable;
        } else {
            writer.print(" style=\"background-image: url({s})\"", .{background}) catch unreachable;
        }
    }
    writer.writeAll(">\n") catch unreachable;
}

fn endSection(writer: Writer, headers: []const []const u8, footers: []const []const u8) void {
    if (headers.len > 0 or footers.len > 0 ) {
        writer.writeAll("\n") catch unreachable;
    }

    if (headers.len > 0) {
        writer.writeAll(indentation ++ "<header>\n") catch unreachable;
        for (headers) |header| {
            writer.writeAll(indentation) catch unreachable;
            beginTag(writer, "p");
            writeLineContent(writer, header);
            endTag(writer, "p");
        }
        writer.writeAll(indentation ++ "</header>\n") catch unreachable;
    }

    if (footers.len > 0) {
        writer.writeAll(indentation ++ "<footer>\n") catch unreachable;
        for (footers) |footer| {
            writer.writeAll(indentation) catch unreachable;
            beginTag(writer, "p");
            writeLineContent(writer, footer);
            endTag(writer, "p");
        }
        writer.writeAll(indentation ++ "</header>\n") catch unreachable;
    }

    writer.writeAll("</section>\n\n") catch unreachable;
}

fn beginListing(writer: Writer) void {
    beginTag(writer, "ul");
    writer.writeAll("\n") catch unreachable;
}

fn endListing(writer: Writer) void {
    writer.writeAll(indentation) catch unreachable;
    endTag(writer, "ul");
}

fn beginTag(writer: Writer, tag: []const u8) void {
    writer.writeAll(indentation ++ "<") catch unreachable;
    writer.writeAll(tag) catch unreachable;
    writer.writeAll(">") catch unreachable;
}

fn endTag(writer: Writer, tag: []const u8) void {
    writer.writeAll("</") catch unreachable;
    writer.writeAll(tag) catch unreachable;
    writer.writeAll(">\n") catch unreachable;
}

fn writeImageTag(writer: Writer, src: []const u8) void {
    writer.writeAll(indentation ++ "<img src=\"") catch unreachable;
    writer.writeAll(src) catch unreachable;
    writer.writeAll("\" />\n") catch unreachable;
}

fn writeLineContent(writer: Writer, line: []const u8) void {
    writer.writeAll(line) catch unreachable;
}

