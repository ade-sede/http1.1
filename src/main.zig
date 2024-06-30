const std = @import("std");
const allocator = std.heap.page_allocator;

const max_read_length = 1024;

const Headers = struct {
    raw: std.ArrayList([]const u8),

    pub fn deinit(self: *Headers) void {
        for (self.raw.items) |h| {
            allocator.free(h);
        }

        self.raw.deinit();
    }
};

const Request = struct {
    method: []const u8,
    target: []const u8,
    http_version: []const u8,

    headers: Headers,

    pub fn deinit(self: *Request) void {
        self.headers.deinit();

        allocator.free(self.method);
        allocator.free(self.target);
        allocator.free(self.http_version);

        allocator.destroy(self);
    }
};

fn readRequestLine(reader: *std.net.Stream.Reader) ![3][]u8 {
    const method = try reader.readUntilDelimiterOrEofAlloc(allocator, ' ', max_read_length) orelse unreachable;
    errdefer allocator.free(method);

    const target = try reader.readUntilDelimiterOrEofAlloc(allocator, ' ', max_read_length) orelse unreachable;
    errdefer allocator.free(target);

    const http_version = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', max_read_length) orelse unreachable;
    errdefer allocator.free(http_version);

    return .{ method, target, http_version };
}

// Note: `readUntil` reads up to the delimiter. The delimiter is consumed but not returned
fn readHeader(reader: *std.net.Stream.Reader) ![]u8 {
    const up_to_delimiter = try reader.readUntilDelimiterOrEofAlloc(allocator, '\r', max_read_length) orelse return error.Empty;
    errdefer allocator.free(up_to_delimiter);

    const line_feed = try reader.readByte();
    if (line_feed != '\n') {
        return error.MissingLineFeed;
    }

    return up_to_delimiter;
}

fn readRequest(reader: *std.net.Stream.Reader) !*Request {
    const request_line = try readRequestLine(reader);

    var request = try allocator.create(Request);
    request.* = Request{
        .method = request_line[0],
        .target = request_line[1],
        .http_version = request_line[2],
        .headers = Headers{
            .raw = std.ArrayList([]const u8).init(allocator),
        },
    };
    errdefer request.deinit();

    while (true) {
        const header_line = try readHeader(reader);

        if (header_line.len == 0) {
            break;
        }

        try request.headers.raw.append(header_line);
    }

    return request;
}

pub fn main() !void {
    const address = try std.net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    var conn = try listener.accept();
    var reader = conn.stream.reader();

    const request = try readRequest(&reader);
    defer request.deinit();

    if (std.mem.eql(u8, request.target, "/")) {
        _ = try conn.stream.write("HTTP/1.1 200 OK\r\n\r\n");
    } else {
        _ = try conn.stream.write("HTTP/1.1 404 Not Found\r\n\r\n");
    }
}
