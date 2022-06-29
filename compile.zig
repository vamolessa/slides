const std = @import("std");

const src_extension = ".slides";
const dst_extension = ".html";

var program_memory: [8 * 1024 * 1024]u8 = undefined;

pub fn main() void {
    const memory = &program_memory;

    {
        var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(memory);

        var args = std.process.args();
        _ = args.skip();
        if (args.next(fixed_buffer_allocator.allocator())) |maybe_arg| {
            const arg = maybe_arg catch {
                std.io.getStdErr().writer().writeAll("could not parse cli arg\n") catch {};
                return;
            };

            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                const stdout = std.io.getStdOut();
                const writer = stdout.writer();
                writer.writeAll(
                    "  --all : recursively compile all " ++ src_extension ++ " sources into " ++ dst_extension ++ "\n",
                ) catch {};
                writer.writeAll("  with no option, will compile stdin into stdout\n") catch {};
                return;
            } else if (std.mem.eql(u8, arg, "--all")) {
                compileAll(memory);
                return;
            } else {
                std.io.getStdErr().writer().print("invalid cli arg: {s}\n", .{arg}) catch {};
                return;
            }
        }
    }

    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();
    compile(memory, stdin, stdout);
}

fn compileAll(memory: []u8) void {
    const stdout = std.io.getStdOut();
    const writer = stdout.writer();

    const cwd = std.fs.cwd().openDir(".", .{ .iterate = true, .no_follow = true }) catch {
        writer.writeAll("could not open current directory for iteration\n") catch {};
        return;
    };

    var dirs = cwd.iterate();
    while (dirs.next() catch null) |dir_entry| {
        if (dir_entry.kind != .Directory) {
            continue;
        }
        if (std.mem.startsWith(u8, dir_entry.name, ".")) {
            continue;
        }

        const dir = cwd.openDir(dir_entry.name, .{ .iterate = true, .no_follow = true }) catch continue;
        var files = dir.iterate();
        while (files.next() catch null) |file_entry| {
            if (file_entry.kind != .File) {
                continue;
            }
            if (!std.mem.endsWith(u8, file_entry.name, src_extension)) {
                continue;
            }

            const src_path = file_entry.name;
            const src_path_without_extension = src_path[0 .. src_path.len - src_extension.len];

            var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(memory);
            const allocator = fixed_buffer_allocator.allocator();

            const dst_path = std.mem.concat(allocator, u8, &.{
                src_path_without_extension,
                dst_extension,
            }) catch {
                writer.writeAll("could not allocate memory for dst path\n") catch {};
                continue;
            };

            const src = dir.openFile(src_path, .{}) catch continue;
            const dst = dir.createFile(dst_path, .{}) catch continue;

            writer.print("compiling {s}/{s} into {s}/{s}\n", .{
                dir_entry.name,
                src_path,
                dir_entry.name,
                dst_path,
            }) catch {};

            compile(memory, src, dst);
        }
    }

    writer.writeAll("done!\n") catch {};
}

const BufferedWriter = std.io.BufferedWriter(4 * 1024, std.fs.File.Writer);
const Writer = BufferedWriter.Writer;

const Link = struct {
    label: []const u8,
    href: []const u8,
};
const Context = struct {
    writer: Writer,
    link_count: u8,
    links: []Link,
};

fn compile(memory: []u8, input: std.fs.File, output: std.fs.File) void {
    const src_len = input.reader().readAll(memory) catch {
        output.writer().writeAll("could read src\n") catch {};
        return;
    };
    if (src_len == memory.len) {
        output.writer().writeAll("input is too big\n") catch {};
        return;
    }
    const src = memory[0..src_len];

    var buffered_writer = BufferedWriter{ .unbuffered_writer = output.writer() };
    defer buffered_writer.flush() catch {};
    var writer = buffered_writer.writer();
    defer endDocument(writer);

    var links_buf: [128]Link = undefined;
    var ctx = Context {
        .writer = writer,
        .link_count = 0,
        .links = &links_buf,
    };

    var begun_document = false;

    const slide_separator = "---";
    var slide_srcs = std.mem.split(u8, src, "\n" ++ slide_separator ++ "\n");
    while (slide_srcs.next()) |slide_src| {
        var title: []const u8 = "";
        var maybe_background: ?[]const u8 = null;

        var header_count: u32 = 0;
        var headers: [32][]const u8 = undefined;
        var footer_count: u32 = 0;
        var footers: [32][]const u8 = undefined;

        const notes_separator = "===";
        const data_len = std.mem.indexOf(u8, slide_src, "\n" ++ notes_separator) orelse slide_src.len;
        const data = slide_src[0..data_len];
        const notes = blk: {
            var notes = slide_src[data_len..];
            if (std.mem.startsWith(u8, notes, "\n" ++ notes_separator)) {
                notes = notes[1 + notes_separator.len..];
            }
            notes = std.mem.trim(u8, notes, " \n\t");
            break :blk notes;
        };

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

        beginSection(&ctx, maybe_background, headers[0..header_count]);
        defer endSection(&ctx, footers[0..footer_count], notes);

        const content_len = first_metadata_offset orelse data.len;
        const content = data[0..content_len];

        var was_inside_list = false;
        var content_lines = std.mem.split(u8, content, "\n");
        while (content_lines.next()) |line| {
            var is_inside_list = false;

            if (consumePrefix(line, "# ")) |heading| {
                writeIndentedTagWithContent(&ctx, "h1", heading);
            } else if (consumePrefix(line, "## ")) |heading| {
                writeIndentedTagWithContent(&ctx, "h2", heading);
            } else if (consumePrefix(line, "- ")) |list_entry| {
                is_inside_list = true;
                if (!was_inside_list) {
                    beginListing(writer);
                }

                write(writer, indentation);
                beginTag(writer, "li");
                writeLineContent(&ctx, list_entry);
                endTag(writer, "li");
                write(writer, "\n");
            } else if (consumePrefix(line, "!!")) |links_heading| {
                const max_per_section = 8;

                const links = ctx.links[0..ctx.link_count];
                defer ctx.link_count = 0;

                writeIndentedTagWithContent(&ctx, "h1", links_heading);

                var link_count: u8 = 0;
                for (links) |link| {
                    defer link_count += 1;
                    if (link_count == max_per_section) {
                        link_count = 0;
                        endSection(&ctx, footers[0..footer_count], "");
                        beginSection(&ctx, maybe_background, headers[0..header_count]);

                        writeIndentedTagWithContent(&ctx, "h1", links_heading);
                    }

                    write(ctx.writer, indentation);
                    writeLinkTag(ctx.writer, link);
                    write(ctx.writer, "\n");
                }
            } else if (consumePrefix(line, "!")) |image_src| {
                writeImageTag(writer, image_src);
            } else if (consumePrefix(line, "```") != null) {
                write(writer, indentation);
                beginTag(writer, "pre");
                beginTag(writer, "code");

                const code_start = content_lines.rest();
                var code_len: usize = 0;

                while(content_lines.next()) |code_line| {
                    if (std.mem.eql(u8, code_line, "```")) {
                        break;
                    } else {
                        code_len += code_line.len + 1;
                    }
                }
                if (code_len > 0) {
                    code_len -= 1;
                }

                var code = code_start[0..code_len];
                while (std.mem.indexOfAny(u8, code, "<>")) |i| {
                    write(writer, code[0..i]);
                    switch (code[i]) {
                        '<' => write(writer, "&lt"),
                        '>' => write(writer, "&gt"),
                        else => unreachable,
                    }
                    code = code[i + 1..];
                }
                write(writer, code);

                endTag(writer, "code");
                endTag(writer, "pre");
                write(writer, "\n");
            } else if (consumePrefix(line, "")) |paragraph| {
                write(writer, indentation);
                beginTag(writer, "p");
                writeLineContent(&ctx, paragraph);
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

fn consumePrefix(bytes: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, prefix)) {
        const rest = bytes[prefix.len..];
        const trimmed = std.mem.trim(u8, rest, " ");
        return if (prefix.len == 0 and trimmed.len == 0) null else trimmed;
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

fn beginSection(
    ctx: *Context,
    maybe_background: ?[]const u8,
    headers: []const []const u8,
) void {
    write(ctx.writer, "<section");
    if (maybe_background) |background| {
        if (std.mem.eql(u8, background, "main")) {
            write(ctx.writer, " class=\"main\"");
        } else {
            write(ctx.writer, " style=\"background-image: url(");
            write(ctx.writer, background);
            write(ctx.writer, ")\"");
        }
    }
    write(ctx.writer, ">\n");

    if (headers.len > 0) {
        write(ctx.writer, indentation);
        beginTag(ctx.writer, "header");
        write(ctx.writer, "\n");
        for (headers) |header| {
            write(ctx.writer, indentation ** 2);
            beginTag(ctx.writer, "p");
            writeLineContent(ctx, header);
            endTag(ctx.writer, "p");
            write(ctx.writer, "\n");
        }
        write(ctx.writer, indentation);
        endTag(ctx.writer, "header");
        write(ctx.writer, "\n\n");
    }
}

fn endSection(ctx: *Context, footers: []const []const u8, notes: []const u8) void {
    if (footers.len > 0) {
        write(ctx.writer, "\n" ++ indentation);
        beginTag(ctx.writer, "footer");
        write(ctx.writer, "\n");
        for (footers) |footer| {
            write(ctx.writer, indentation ** 2);
            beginTag(ctx.writer, "p");
            writeLineContent(ctx, footer);
            endTag(ctx.writer, "p");
            write(ctx.writer, "\n");
        }
        write(ctx.writer, indentation);
        endTag(ctx.writer, "footer");
        write(ctx.writer, "\n");
    }

    if (notes.len > 0) {
        write(ctx.writer, "\n" ++ indentation ++ "<!--\n");
        var notes_lines = std.mem.split(u8, notes, "\n");
        while (notes_lines.next()) |line| {
            write(ctx.writer, indentation);
            write(ctx.writer, line);
            write(ctx.writer, "\n");
        }
        write(ctx.writer, indentation ++ "-->\n");
    }

    endTag(ctx.writer, "section");
    write(ctx.writer, "\n\n");
}

fn write(writer: Writer, bytes: []const u8) void {
    writer.writeAll(bytes) catch std.debug.panic("could not write bytes\n", .{});
}

fn writeByte(writer: Writer, byte: u8) void {
    writer.writeByte(byte) catch std.debug.panic("could not write bytes\n", .{});
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

fn writeIndentedTagWithContent(ctx: *Context, tag: []const u8, content: []const u8) void {
    write(ctx.writer, indentation);
    beginTag(ctx.writer, tag);
    writeLineContent(ctx, content);
    endTag(ctx.writer, "h1");
    write(ctx.writer, "\n");
}

fn writeLinkTag(writer: Writer, link: Link) void {
    write(writer, "<a href=\"");
    write(writer, link.href);
    write(writer, "\">");
    write(writer, link.label);
    endTag(writer, "a");
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

fn writeLineContent(ctx: *Context, line: []const u8) void {
    var bytes = line;
    while (nextByte(&bytes)) |byte| {
        switch (byte) {
            '\\' => {
                if (nextByte(&bytes)) |b| {
                    _ = b;
                    writeByte(ctx.writer, b);
                }
                continue;
            },
            '[' => {
                const separator = "](";
                if (std.mem.indexOf(u8, bytes, separator)) |label_end| {
                    const label = bytes[0..label_end];
                    const href_start = label_end + separator.len;
                    if (std.mem.indexOfScalarPos(u8, bytes, href_start, ')')) |href_end| {
                        const link = Link {
                            .href = bytes[href_start..href_end],
                            .label = label,
                        };
                        writeLinkTag(ctx.writer, link);
                        bytes = bytes[href_end + 1 ..];

                        if (ctx.link_count < ctx.links.len) {
                            ctx.links[ctx.link_count] = link;
                            ctx.link_count += 1;
                        }
                        continue;
                    }
                }
            },
            '*' => {
                if (std.mem.indexOfScalar(u8, bytes, '*')) |len| {
                    beginTag(ctx.writer, "em");
                    write(ctx.writer, bytes[0..len]);
                    endTag(ctx.writer, "em");

                    bytes = bytes[len + 1 ..];
                    continue;
                }
            },
            '`' => {
                if (std.mem.indexOfScalar(u8, bytes, '`')) |len| {
                    beginTag(ctx.writer, "code");
                    write(ctx.writer, bytes[0..len]);
                    endTag(ctx.writer, "code");

                    bytes = bytes[len + 1 ..];
                    continue;
                }
            },
            else => {},
        }

        writeByte(ctx.writer, byte);
    }
}

