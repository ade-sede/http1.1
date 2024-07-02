const std = @import("std");

const max_read_length = 1024;

const Headers = struct {
    allocator: std.mem.Allocator,
    raw: std.ArrayList([]const u8),

    pub fn deinit(self: *Headers) void {
        for (self.raw.items) |h| {
            self.allocator.free(h);
        }

        self.raw.deinit();
    }
};

const Method = enum {
    GET,
    POST,
};

const Request = struct {
    allocator: std.mem.Allocator,
    method: Method,
    target: []const u8,
    // `segments` borrow from target
    segments: std.ArrayList([]const u8),
    http_version: []const u8,

    headers: Headers,

    pub fn init(allocator: std.mem.Allocator) !*Request {
        const request = try allocator.create(Request);
        request.* = Request{
            .allocator = allocator,
            .method = undefined,
            .target = undefined,
            .http_version = undefined,
            .segments = std.ArrayList([]const u8).init(allocator),
            .headers = Headers{
                .allocator = allocator,
                .raw = std.ArrayList([]const u8).init(allocator),
            },
        };

        return request;
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
        self.segments.deinit();

        self.allocator.free(self.target);
        self.allocator.free(self.http_version);

        self.allocator.destroy(self);
    }
};

const Response = struct {
    allocator: std.mem.Allocator,
    code: u64,
    http_version: []const u8,
    reason: []const u8,
    headers: Headers,
    body: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) !*Response {
        const response = try allocator.create(Response);
        response.* = Response{
            .allocator = allocator,
            .http_version = undefined,
            .code = undefined,
            .reason = undefined,
            .headers = Headers{
                .allocator = allocator,
                .raw = std.ArrayList([]const u8).init(allocator),
            },
            .body = undefined,
        };

        return response;
    }

    pub fn @"404"(allocator: std.mem.Allocator) !*Response {
        var response = try Response.init(allocator);

        response.code = 404;
        response.http_version = try allocator.dupe(u8, "HTTP/1.1");
        response.reason = try allocator.dupe(u8, "Not Found");
        response.body = null;
    }

    pub fn @"422"(allocator: std.mem.Allocator) !*Response {
        var response = try Response.init(allocator);

        response.code = 422;
        response.http_version = try allocator.dupe(u8, "HTTP/1.1");
        response.reason = try allocator.dupe(u8, "Unprocessable Content");
        response.body = null;
    }

    pub fn text(allocator: std.mem.Allocator, txt: []const u8) !*Response {
        var response = try Response.init(allocator);

        response.code = 200;
        response.http_version = try allocator.dupe(u8, "HTTP/1.1");
        response.reason = try allocator.dupe(u8, "OK");
        response.body = try allocator.dupe(u8, txt);

        try response.headers.raw.append(try allocator.dupe(u8, "Content-Type: text/plain"));
        try response.headers.raw.append(try std.fmt.allocPrint(allocator, "Content-Length: {d}", .{txt.len}));

        return response;
    }

    pub fn file(allocator: std.mem.Allocator, file_content: []const u8) !*Response {
        var response = try Response.init(allocator);

        response.code = 200;
        response.http_version = try allocator.dupe(u8, "HTTP/1.1");
        response.reason = try allocator.dupe(u8, "OK");
        response.body = file_content;

        try response.headers.raw.append(try allocator.dupe(u8, "Content-Type: application/octet-stream"));
        try response.headers.raw.append(try std.fmt.allocPrint(allocator, "Content-Length: {d}", .{file_content.len}));

        return response;
    }

    fn packHeaders(allocator: std.mem.Allocator, headers: []const []const u8) ![]const u8 {
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
        const status_line = try std.fmt.allocPrint(self.allocator, "{s} {d} {s}\r\n", .{ self.http_version, self.code, self.reason });
        defer self.allocator.free(status_line);

        const header_section = try Response.packHeaders(self.allocator, self.headers.raw.items);
        defer self.allocator.free(header_section);

        if (self.body) |body| {
            return std.mem.concat(self.allocator, u8, &[_][]const u8{ status_line, header_section, body });
        }

        return std.mem.concat(self.allocator, u8, &[_][]const u8{ status_line, header_section });
    }

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.http_version);
        self.allocator.free(self.reason);

        if (self.body) |body| {
            self.allocator.free(body);
        }

        self.headers.deinit();
    }
};

fn readRequestLine(allocator: std.mem.Allocator, reader: *std.net.Stream.Reader) ![3][]u8 {
    const method = try reader.readUntilDelimiterOrEofAlloc(allocator, ' ', max_read_length) orelse unreachable;
    errdefer allocator.free(method);

    const target = try reader.readUntilDelimiterOrEofAlloc(allocator, ' ', max_read_length) orelse unreachable;
    errdefer allocator.free(target);

    const http_version = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', max_read_length) orelse unreachable;
    errdefer allocator.free(http_version);

    return .{ method, target, http_version };
}

// Note: `readUntil` reads up to the delimiter. The delimiter is consumed but not returned
fn readHeader(allocator: std.mem.Allocator, reader: *std.net.Stream.Reader) ![]u8 {
    const up_to_delimiter = try reader.readUntilDelimiterOrEofAlloc(allocator, '\r', max_read_length) orelse return error.Empty;
    errdefer allocator.free(up_to_delimiter);

    const line_feed = try reader.readByte();
    if (line_feed != '\n') {
        return error.MissingLineFeed;
    }

    return up_to_delimiter;
}

fn readRequest(allocator: std.mem.Allocator, reader: *std.net.Stream.Reader) !*Request {
    const request_line = try readRequestLine(allocator, reader);

    var request = try Request.init(allocator);
    errdefer request.deinit();

    request.method = blk: {
        if (std.mem.eql(u8, request_line[0], "GET")) {
            break :blk Method.GET;
        } else if (std.mem.eql(u8, request_line[0], "POST")) {
            break :blk Method.POST;
        } else {
            return error.UnsupportedMethod;
        }
    };

    request.target = request_line[1];
    request.http_version = request_line[2];

    var iterator = std.mem.tokenizeSequence(u8, request.target, "/");
    while (iterator.next()) |segment| {
        try request.segments.append(segment);
    }

    while (true) {
        const header_line = try readHeader(allocator, reader);

        if (header_line.len == 0) {
            break;
        }

        try request.headers.raw.append(header_line);
    }

    return request;
}

fn echo(allocator: std.mem.Allocator, request: *Request, stream: std.net.Stream) !void {
    if (request.segments.items.len != 2) {
        _ = try stream.write("HTTP/1.1 422 Unprocessable Content\r\n\r\n");
        return;
    }

    const response = try Response.text(allocator, request.segments.items[1]);
    defer response.deinit();
    const bytes = try response.pack();
    defer allocator.free(bytes);

    _ = try stream.write(bytes);
}

fn userAgent(allocator: std.mem.Allocator, request: *Request, stream: std.net.Stream) !void {
    if (request.segments.items.len != 1) {
        _ = try stream.write("HTTP/1.1 422 Unprocessable Content\r\n\r\n");
        return;
    }

    const user_agent: []const u8 = blk: {
        for (request.headers.raw.items) |header| {
            if (std.mem.startsWith(u8, header, "User-Agent: ")) {
                // `User-Agent: <value>`
                if (std.mem.indexOf(u8, header, ": ")) |index| {
                    break :blk header[index + 2 ..];
                }
            }
        } else {
            _ = try stream.write("HTTP/1.1 400 Bad Request\r\n\r\n");
            return;
        }
    };

    const response = try Response.text(allocator, user_agent);
    defer response.deinit();
    const bytes = try response.pack();
    defer allocator.free(bytes);

    _ = try stream.write(bytes);
}

fn file(allocator: std.mem.Allocator, request: *Request, stream: std.net.Stream) !void {
    if (request.segments.items.len != 2) {
        _ = try stream.write("HTTP/1.1 422 Unprocessable Content\r\n\r\n");
        return;
    }

    const filename = request.segments.items[1];
    const dir = try std.fs.openDirAbsoluteZ(directory, std.fs.Dir.OpenDirOptions{});
    const file_handler = dir.openFile(filename, std.fs.File.OpenFlags{
        .mode = .read_only,
    }) catch {
        _ = try stream.write("HTTP/1.1 404 Not Found\r\n\r\n");
        return;
    };

    const file_content = try file_handler.readToEndAlloc(allocator, 1024 * 1024);

    const response = try Response.file(allocator, file_content);
    defer response.deinit();
    const bytes = try response.pack();
    defer allocator.free(bytes);

    _ = try stream.write(bytes);
}

fn do(allocator: std.mem.Allocator, conn: std.net.Server.Connection) !void {
    var reader = conn.stream.reader();

    const request = try readRequest(allocator, &reader);
    defer request.deinit();

    if (std.mem.eql(u8, request.target, "/")) {
        _ = try conn.stream.write("HTTP/1.1 200 OK\r\n\r\n");
    } else if (std.mem.startsWith(u8, request.target, "/echo")) {
        return echo(allocator, request, conn.stream);
    } else if (std.mem.startsWith(u8, request.target, "/user-agent")) {
        return userAgent(allocator, request, conn.stream);
    } else if (std.mem.startsWith(u8, request.target, "/files")) {
        return file(allocator, request, conn.stream);
    } else {
        _ = try conn.stream.write("HTTP/1.1 404 Not Found\r\n\r\n");
    }
}

fn handleConnection(allocator: std.mem.Allocator, conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    do(allocator, conn) catch {
        _ = conn.stream.write("HTTP/1.1 500 Server Error\r\n\r\n") catch {};
    };
}

var directory: [:0]const u8 = undefined;

pub fn main() !void {
    var args = std.process.args();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "--directory", arg)) {
            directory = args.next() orelse {
                std.debug.print("Missing directory name", .{});
                return error.NoDirectoryName;
            };
        }
    }

    const address = try std.net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    var allocator = std.heap.ThreadSafeAllocator{ .child_allocator = std.heap.page_allocator };
    var pool: std.Thread.Pool = undefined;

    try pool.init(std.Thread.Pool.Options{
        .allocator = allocator.child_allocator,
        .n_jobs = 10,
    });
    defer pool.deinit();

    while (true) {
        const conn = try listener.accept();
        try pool.spawn(handleConnection, .{ allocator.allocator(), conn });
    }
}
