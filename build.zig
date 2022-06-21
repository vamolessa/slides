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

    const slide_separator = "---";
    var slide_srcs = std.mem.split(u8, src, "\n" ++ slide_separator ++ "\n");
    while(slide_srcs.next()) |slide_src| {
        var title: []const u8 = "";
        var maybe_background: ?[]const u8 = null;

        var header_count: u32 = 0;
        var headers: [32][]const u8 = undefined;
        var footer_count: u32 = 0;
        var footers: [32][]const u8 = undefined;

        const notes_separator = "===";
        const data_len = std.mem.indexOf(u8, slide_src, "\n" ++ notes_separator) orelse slide_src.len;
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
            } else if (consumePrefix(line, "# ")) |heading| {
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

        beginSection(writer, maybe_background, headers[0..header_count]);
        defer endSection(writer, footers[0..footer_count]);

        const content_len = first_metadata_offset orelse data.len;
        const content = data[0..content_len];

        var was_inside_list = false;
        var content_lines = std.mem.split(u8, content, "\n");
        while (content_lines.next()) |line| {
            var is_inside_list = false;

            if (consumePrefix(line, "# ")) |heading| {
                write(writer, indentation);
                beginTag(writer, "h1");
                writeLineContent(writer, heading);
                endTag(writer, "h1");
                write(writer, "\n");
            } else if (consumePrefix(line, "## ")) |heading| {
                write(writer, indentation);
                beginTag(writer, "h2");
                writeLineContent(writer, heading);
                endTag(writer, "h2");
                write(writer, "\n");
            } else if (consumePrefix(line, "- ")) |list_entry| {
                is_inside_list = true;
                if (!was_inside_list) {
                    beginListing(writer);
                }

                write(writer, indentation);
                beginTag(writer, "li");
                writeLineContent(writer, list_entry);
                endTag(writer, "li");
                write(writer, "\n");
            } else if (consumePrefix(line, "!")) |image_src| {
                writeImageTag(writer, image_src);
            } else if (consumePrefix(line, "")) |paragraph| {
                write(writer, indentation);
                beginTag(writer, "p");
                writeLineContent(writer, paragraph);
                endTag(writer, "p");
                write(writer, "\n");
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
    const before_title =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<link rel="stylesheet" type="text/css" href="../style.css">
        \\<title>
        ;
    const after_title =
        \\</title>
        \\</head>
        \\<body>
        \\
        \\
        ;
    write(writer, before_title);
    write(writer, title);
    write(writer, after_title);
}

fn endDocument(writer: Writer) void {
    const postfix =
        \\</body>
        \\</html>
        \\
        ;
    write(writer, postfix);
}

const indentation = " " ** 4;

fn beginSection(writer: Writer, maybe_background: ?[]const u8, headers: []const []const u8) void {
    write(writer, "<section");
    if (maybe_background) |background| {
        if (std.mem.eql(u8, background, "main")) {
            write(writer, " class=\"main\"");
        } else {
            write(writer, " style=\"background-image: url(");
            write(writer, background);
            write(writer, ")\"");
        }
    }
    write(writer, ">\n");

    if (headers.len > 0) {
        write(writer, indentation);
        beginTag(writer, "header");
        write(writer, "\n");
        for (headers) |header| {
            write(writer, indentation ** 2);
            beginTag(writer, "p");
            writeLineContent(writer, header);
            endTag(writer, "p");
            write(writer, "\n");
        }
        write(writer, indentation);
        endTag(writer, "header");
        write(writer, "\n\n");
    }
}

fn endSection(writer: Writer, footers: []const []const u8) void {
    if (footers.len > 0) {
        write(writer, "\n" ++ indentation);
        beginTag(writer, "footer");
        write(writer, "\n");
        for (footers) |footer| {
            write(writer, indentation ** 2);
            beginTag(writer, "p");
            writeLineContent(writer, footer);
            endTag(writer, "p");
            write(writer, "\n");
        }
        write(writer, indentation);
        endTag(writer, "footer");
        write(writer, "\n");
    }

    endTag(writer, "section");
    write(writer, "\n\n");
}

fn write(writer: Writer, bytes: []const u8) void {
    writer.writeAll(bytes) catch unreachable;
}

fn writeByte(writer: Writer, byte: u8) void {
    writer.writeByte(byte) catch unreachable;
}

fn beginListing(writer: Writer) void {
    write(writer, indentation);
    beginTag(writer, "ul");
    write(writer, "\n");
}

fn endListing(writer: Writer) void {
    write(writer, indentation);
    endTag(writer, "ul");
    write(writer, "\n");
}

fn beginTag(writer: Writer, tag: []const u8) void {
    write(writer, "<");
    write(writer, tag);
    write(writer, ">");
}

fn endTag(writer: Writer, tag: []const u8) void {
    write(writer, "</");
    write(writer, tag);
    write(writer, ">");
}

fn writeImageTag(writer: Writer, src: []const u8) void {
    write(writer, indentation ++ "<img src=\"");
    write(writer, src);
    write(writer, "\" />\n");
}

fn nextByte(line: *[]const u8) ?u8 {
    if (line.len > 0) {
        const byte = line.*[0];
        line.* = line.*[1..];
        return byte;
    } else {
        return null;
    }
}

fn writeLineContent(writer: Writer, line: []const u8) void {
    var bytes = line;
    while (nextByte(&bytes)) |byte| {
        switch (byte) {
            '\\' => {
                if (nextByte(&bytes)) |b| {
                    _ = b;
                    writeByte(writer, b);
                }
                continue;
            },
            '[' => {
                const separator = "](";
                if (std.mem.indexOf(u8, bytes, separator)) |label_end| {
                    const label = bytes[0..label_end];
                    const link_start = label_end + separator.len;
                    if (std.mem.indexOfScalarPos(u8, bytes, link_start, ')')) |link_end| {
                        const link = bytes[link_start..link_end];

                        write(writer, "<a href=\"");
                        write(writer, link);
                        write(writer, "\">");
                        write(writer, label);
                        endTag(writer, "a");

                        bytes = bytes[link_end + 1..];
                        continue;
                    }
                }
            },
            '*' => {
                if (std.mem.indexOfScalar(u8, bytes, '*')) |len| {
                    beginTag(writer, "em");
                    write(writer, bytes[0..len]);
                    endTag(writer, "em");

                    bytes = bytes[len + 1..];
                    continue;
                }
            },
            else => {},
        }

        writeByte(writer, byte);
    }
}

