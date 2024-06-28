const std = @import("std");

const max_part_length = 1024;

const Request = struct {
    allocator: std.mem.Allocator,

    status_line: []const u8,
    requestType: []const u8,
    path: []const u8,
    protocol: []const u8,

    headers: std.ArrayList([]const u8),

    pub fn free(self: *Request) void {
        for (self.headers.items) |h| {
            self.allocator.free(h);
        }

        self.headers.deinit();
        self.allocator.free(self.status_line);
    }
};

fn readRequestPart(allocator: std.mem.Allocator, reader: *std.net.Stream.Reader) ![]u8 {
    // Note: delimiter is consumed but not part of returned slice.
    const up_to_delimiter = try reader.readUntilDelimiterOrEofAlloc(allocator, '\r', max_part_length) orelse return error.Empty;
    errdefer allocator.free(up_to_delimiter);

    const line_feed = try reader.readByte();
    if (line_feed != '\n') return error.CarriageReturnWithinPart;

    return up_to_delimiter;
}

fn readRequest(allocator: std.mem.Allocator, reader: *std.net.Stream.Reader) !*Request {
    const status_line = try readRequestPart(allocator, reader);

    var request = Request{
        .allocator = allocator,
        .headers = std.ArrayList([]const u8).init(allocator),
        .status_line = status_line,
        .requestType = undefined,
        .path = undefined,
        .protocol = undefined,
    };
    errdefer request.free();

    var iterator = std.mem.splitAny(u8, request.status_line, " ");
    var index: usize = 0;

    while (iterator.next()) |value| : (index += 1) {
        switch (index) {
            0 => request.requestType = value,
            1 => request.path = value,
            2 => request.protocol = value,
            else => return error.TooManyArgumentsInStatusLine,
        }
    }

    while (true) {
        const header_line = try readRequestPart(allocator, reader);

        if (header_line.len == 0) {
            break;
        }

        try request.headers.append(header_line);
    }

    return &request;
}

pub fn main() !void {
    // const stdout = std.io.getStdOut().writer();
    const allocator = std.heap.page_allocator;

    const address = try std.net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    var conn = try listener.accept();
    var reader = conn.stream.reader();

    const request = try readRequest(allocator, &reader);
    defer request.free();

    if (std.mem.eql(u8, request.path, "/")) {
        _ = try conn.stream.write("HTTP/1.1 200 OK\r\n\r\n");
    } else {
        _ = try conn.stream.write("HTTP/1.1 404 Not Found\r\n\r\n");
    }
}
