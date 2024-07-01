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
    // `segments` borrow from target
    segments: std.ArrayList([]const u8),
    http_version: []const u8,

    headers: Headers,

    pub fn init() !*Request {
        const request = try allocator.create(Request);
        request.* = Request{
            .method = undefined,
            .target = undefined,
            .http_version = undefined,
            .segments = std.ArrayList([]const u8).init(allocator),
            .headers = Headers{
                .raw = std.ArrayList([]const u8).init(allocator),
            },
        };

        return request;
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
        self.segments.deinit();

        allocator.free(self.method);
        allocator.free(self.target);
        allocator.free(self.http_version);

        allocator.destroy(self);
    }
};

const Response = struct {
    code: u64,
    http_version: []const u8,
    reason: []const u8,
    headers: Headers,
    body: ?[]const u8,

    pub fn init() !*Response {
        const response = try allocator.create(Response);
        response.* = Response{
            .http_version = undefined,
            .code = undefined,
            .reason = undefined,
            .headers = Headers{
                .raw = std.ArrayList([]const u8).init(allocator),
            },
            .body = undefined,
        };

        return response;
    }

    pub fn @"404"() !*Response {
        var response = try Response.init();

        response.code = 404;
        response.http_version = try allocator.dupe(u8, "HTTP/1.1");
        response.reason = try allocator.dupe(u8, "Not Found");
        response.body = null;
    }

    pub fn @"422"() !*Response {
        var response = try Response.init();

        response.code = 422;
        response.http_version = try allocator.dupe(u8, "HTTP/1.1");
        response.reason = try allocator.dupe(u8, "Unprocessable Content");
        response.body = null;
    }

    pub fn text(txt: []const u8) !*Response {
        var response = try Response.init();

        response.code = 200;
        response.http_version = try allocator.dupe(u8, "HTTP/1.1");
        response.reason = try allocator.dupe(u8, "OK");
        response.body = try allocator.dupe(u8, txt);

        try response.headers.raw.append(try allocator.dupe(u8, "Content-Type: text/plain"));
        try response.headers.raw.append(try std.fmt.allocPrint(allocator, "Content-Length: {d}", .{txt.len}));

        return response;
    }

    fn packHeaders(headers: []const []const u8) ![]const u8 {
        // A header section is of the form
        //
        // header_line\r\n
        // header_line\r\n
        // \r\n (trailing CRLF to mark end of section)

        const packed_headers = try std.mem.join(allocator, "\r\n", headers);
        defer allocator.free(packed_headers);

        if (headers.len != 0) {
            return std.mem.concat(allocator, u8, &[_][]const u8{ packed_headers, "\r\n", "\r\n" });
        } else {
            return std.mem.concat(allocator, u8, &[_][]const u8{ packed_headers, "\r\n" });
        }
    }

    pub fn pack(self: *Response) ![]const u8 {
        const status_line = try std.fmt.allocPrint(allocator, "{s} {d} {s}\r\n", .{ self.http_version, self.code, self.reason });
        defer allocator.free(status_line);

        const header_section = try Response.packHeaders(self.headers.raw.items);
        defer allocator.free(header_section);

        if (self.body) |body| {
            return std.mem.concat(allocator, u8, &[_][]const u8{ status_line, header_section, body });
        }

        return std.mem.concat(allocator, u8, &[_][]const u8{ status_line, header_section });
    }

    pub fn deinit(self: *Response) void {
        allocator.free(self.http_version);
        allocator.free(self.reason);

        if (self.body) |body| {
            allocator.free(body);
        }

        self.headers.deinit();
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

    var request = try Request.init();
    errdefer request.deinit();

    request.method = request_line[0];
    request.target = request_line[1];
    request.http_version = request_line[2];

    var iterator = std.mem.tokenizeSequence(u8, request.target, "/");
    while (iterator.next()) |segment| {
        try request.segments.append(segment);
    }

    while (true) {
        const header_line = try readHeader(reader);

        if (header_line.len == 0) {
            break;
        }

        try request.headers.raw.append(header_line);
    }

    return request;
}

fn echo(request: *Request, stream: *std.net.Stream) !void {
    const response = try Response.text(request.segments.items[1]);
    const bytes = try response.pack();

    std.debug.print("{s}", .{bytes});

    _ = try stream.write(bytes);
}

pub fn main() !void {
    const address = try std.net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    while (true) {
        var conn = try listener.accept();
        var reader = conn.stream.reader();
        const request = try readRequest(&reader);
        defer request.deinit();

        if (std.mem.eql(u8, request.target, "/")) {
            _ = try conn.stream.write("HTTP/1.1 200 OK\r\n\r\n");
        } else if (std.mem.startsWith(u8, request.target, "/echo/")) {
            if (request.segments.items.len == 2) {
                return echo(request, &conn.stream);
            }
            _ = try conn.stream.write("HTTP/1.1 422 Unprocessable Content\r\n\r\n");
        } else {
            _ = try conn.stream.write("HTTP/1.1 404 Not Found\r\n\r\n");
        }
    }
}
