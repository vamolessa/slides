const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const args = b.args orelse {
        std.log.err("no slides to build", .{});
        return;
    };

    var memory = b.allocator.alloc(u8, 8 * 1024 * 1024) catch unreachable;
    for (args) |arg| {
        buildSlide(memory, arg);
    }

    std.log.info("done", .{});
}

fn buildSlide(memory: []u8, src_path: []const u8) void {
    const src_extension = std.fs.path.extension(src_path);
    const dst_extension = ".html";
    if (std.mem.eql(u8, src_extension, dst_extension)) {
        std.log.err("src extension: {s} is the same as dst", .{src_path});
        return;
    }

    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(memory);
    var allocator = fixed_buffer_allocator.allocator();
    const dst_path = std.mem.concat(allocator, u8, &.{
        src_path[0 .. src_path.len - src_extension.len],
        dst_extension,
    }) catch unreachable;

    std.log.info("generating slide {s}", .{dst_path});

    const cwd = std.fs.cwd();
    var dst_file = cwd.createFile(dst_path, .{}) catch |err| {
        std.log.err("could not write to {s}: {}", .{ dst_path, err });
        return;
    };
    defer dst_file.close();

    const src = cwd.readFile(src_path, memory) catch |err| {
        std.log.err("could not read from {s}: {}", .{ src_path, err });
        return;
    };

    var reader = Reader{ .src = src };
    var buffered_writer = BufferedWriter{ .unbuffered_writer = dst_file.writer() };
    defer buffered_writer.flush() catch |err| {
        std.log.err("could not flush writer for {s}: {}", .{ src_path, err });
    };

    var writer = Writer {
        .buffered_writer = &buffered_writer,
    };
    parseAndGenerate(&reader, &writer);
}

const Reader = struct {
    src: []const u8,

    const Self = @This();
    const Reader = std.io.Reader(*Self, Error, read);
    const Error = error {};
    fn read(self: *Self, bytes: []u8) Error!usize {
        const len = std.math.min(self.src.len, bytes.len);
        std.mem.copy(u8, bytes, self.src[0..len]);
        self.src = self.src[len..];
        return len;
    }

    fn reader(self: *Self) Self.Reader {
        return .{ .context = self };
    }
};

const BufferedWriter = std.io.BufferedWriter(4 * 1024, std.fs.File.Writer);

const Writer = struct {
    buffered_writer: *BufferedWriter,
    generated_prefix: bool = false,

    pub fn writer(self: *Writer) BufferedWriter.Writer {
        return self.buffered_writer.writer();
    }
};

fn parseAndGenerate(reader: *Reader, writer: *Writer) void {
    writePrefix(writer, "test title");
    writePostfix(writer);
    _ = reader;
}

fn writePrefix(writer: *Writer, title: []const u8) void {
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

    writer.writer().print(prefix, .{title}) catch unreachable;
}

fn writePostfix(writer: *Writer) void {
    const postfix =
        \\
        \\
        \\</body>
        \\
        ;

    writer.writer().writeAll(postfix) catch unreachable;
}
