const std = @import("std");
const gzip = std.compress.gzip;

const max_read_length = 1024;

const Headers = struct {
    allocator: std.mem.Allocator,
    raw: std.ArrayList([]const u8),
    content_length: ?usize,
    // slice of raw, no need to free items
    accept_encoding: ?std.ArrayList([]const u8),

    pub fn deinit(self: *Headers) void {
        for (self.raw.items) |h| {
            self.allocator.free(h);
        }

        if (self.accept_encoding) |encoding_list| {
            encoding_list.deinit();
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

    body: ?[]const u8,

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
                .content_length = null,
                .accept_encoding = null,
            },
            .body = null,
        };

        return request;
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
        self.segments.deinit();

        self.allocator.free(self.target);
        self.allocator.free(self.http_version);

        if (self.body) |body| {
            self.allocator.free(body);
        }

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
                .content_length = null,
                .accept_encoding = null,
            },
            .body = null,
        };

        return response;
    }

    pub fn @"404"() []const u8 {
        return "HTTP/1.1 404 Not Found\r\n\r\n";
    }

    pub fn @"422"() []const u8 {
        return "HTTP/1.1 422 Unprocessable Content\r\n\r\n";
    }

    pub fn @"500"() []const u8 {
        return "HTTP/1.1 500 Server Error\r\n\r\n";
    }

    pub fn text(allocator: std.mem.Allocator, txt: []const u8) !*Response {
        var response = try Response.init(allocator);

        response.code = 200;
        response.http_version = try allocator.dupe(u8, "HTTP/1.1");
        response.reason = try allocator.dupe(u8, "OK");
        response.body = try allocator.dupe(u8, txt);

        try response.headers.raw.append(try allocator.dupe(u8, "Content-Type: text/plain"));
        response.headers.content_length = txt.len;

        return response;
    }

    pub fn file(allocator: std.mem.Allocator, file_content: []const u8) !*Response {
        var response = try Response.init(allocator);

        response.code = 200;
        response.http_version = try allocator.dupe(u8, "HTTP/1.1");
        response.reason = try allocator.dupe(u8, "OK");
        response.body = file_content;

        try response.headers.raw.append(try allocator.dupe(u8, "Content-Type: application/octet-stream"));
        response.headers.content_length = file_content.len;

        return response;
    }

    fn packHeaders(self: *Response) ![]const u8 {
        // A header section is of the form
        //
        // header_line\r\n
        // header_line\r\n
        // \r\n (trailing CRLF to mark end of section)

        if (self.headers.content_length) |len| {
            try self.headers.raw.append(try std.fmt.allocPrint(self.allocator, "Content-Length: {d}", .{len}));
        }

        const packed_headers = try std.mem.join(self.allocator, "\r\n", self.headers.raw.items);
        defer self.allocator.free(packed_headers);

        if (self.headers.raw.items.len != 0) {
            return std.mem.concat(self.allocator, u8, &[_][]const u8{ packed_headers, "\r\n", "\r\n" });
        } else {
            return std.mem.concat(self.allocator, u8, &[_][]const u8{ packed_headers, "\r\n" });
        }
    }

    fn encode(self: *Response, request_headers: *Headers) !void {
        if (self.body) |uncompressed_body| {
            if (request_headers.accept_encoding) |encodings| {
                const encoding_to_use: []const u8 = blk: {
                    for (encodings.items) |encoding| {
                        if (std.mem.eql(u8, encoding, "gzip")) {
                            break :blk "gzip";
                        }
                    } else {
                        return error.InvalidEncodingRequested;
                    }
                };

                const encoding_header = try std.fmt.allocPrint(self.headers.allocator, "Content-Encoding: {s}", .{encoding_to_use});
                try self.headers.raw.append(encoding_header);

                if (std.mem.eql(u8, encoding_to_use, "gzip")) {
                    var compressed = std.ArrayList(u8).init(self.allocator);
                    defer compressed.deinit();

                    var uncompressed = std.io.fixedBufferStream(uncompressed_body);

                    try gzip.compress(uncompressed.reader(), compressed.writer(), gzip.Options{});

                    self.allocator.free(uncompressed_body);
                    self.body = try self.allocator.dupe(u8, compressed.items);
                    self.headers.content_length = compressed.items.len;
                }
            }
        }
    }

    pub fn pack(self: *Response, request_headers: *Headers) ![]const u8 {
        self.encode(request_headers) catch |err| {
            switch (err) {
                error.InvalidEncodingRequested => {},
                else => return err,
            }
        };

        const status_line = try std.fmt.allocPrint(self.allocator, "{s} {d} {s}\r\n", .{ self.http_version, self.code, self.reason });
        defer self.allocator.free(status_line);

        const header_section = try self.packHeaders();
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

        if (std.mem.startsWith(u8, header_line, "Content-Length:")) {
            if (std.mem.indexOf(u8, header_line, ": ")) |index| {
                const length = try std.fmt.parseInt(usize, header_line[index + 2 ..], 10);

                if (length > 0) {
                    request.headers.content_length = length;
                }
            }
        }

        if (std.mem.startsWith(u8, header_line, "Accept-Encoding:")) {
            if (std.mem.indexOf(u8, header_line, ": ")) |index| {
                request.headers.accept_encoding = std.ArrayList([]const u8).init(allocator);

                const encodings = header_line[index + 2 ..];
                var encoding_iterator = std.mem.splitSequence(u8, encodings, ",");

                while (encoding_iterator.next()) |encoding_format| {
                    const trimed = std.mem.trim(u8, encoding_format, " ");
                    try request.headers.accept_encoding.?.append(trimed);
                }
            }
        }
    }

    if (request.headers.content_length) |length| {
        var body: []u8 = undefined;
        body = try allocator.allocSentinel(u8, length, 0);
        _ = try reader.read(body);

        request.body = body;
    }

    return request;
}

fn echo(allocator: std.mem.Allocator, request: *Request, stream: std.net.Stream) !void {
    if (request.segments.items.len != 2) {
        _ = try stream.write(Response.@"422"());
        return;
    }

    const response = try Response.text(allocator, request.segments.items[1]);
    defer response.deinit();
    const bytes = try response.pack(&request.headers);
    defer allocator.free(bytes);

    _ = try stream.write(bytes);
}

fn userAgent(allocator: std.mem.Allocator, request: *Request, stream: std.net.Stream) !void {
    if (request.segments.items.len != 1) {
        _ = try stream.write(Response.@"422"());
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
    const bytes = try response.pack(&request.headers);
    defer allocator.free(bytes);

    _ = try stream.write(bytes);
}

fn postFile(request: *Request, stream: std.net.Stream) !void {
    if (request.segments.items.len != 2) {
        _ = try stream.write(Response.@"422"());
        return;
    }

    const filename = request.segments.items[1];
    const dir = try std.fs.openDirAbsoluteZ(directory, std.fs.Dir.OpenDirOptions{});
    const file_handler = try dir.createFile(filename, std.fs.File.CreateFlags{
        .read = false,
        .truncate = true,
    });
    defer file_handler.close();

    if (request.body) |body| {
        _ = try file_handler.write(body);
    }

    _ = try stream.write("HTTP/1.1 201 Created\r\n\r\n");
}

fn getFile(allocator: std.mem.Allocator, request: *Request, stream: std.net.Stream) !void {
    if (request.segments.items.len != 2) {
        _ = try stream.write(Response.@"422"());
        return;
    }

    const filename = request.segments.items[1];
    const dir = try std.fs.openDirAbsoluteZ(directory, std.fs.Dir.OpenDirOptions{});
    const file_handler = dir.openFile(filename, std.fs.File.OpenFlags{
        .mode = .read_only,
    }) catch {
        _ = try stream.write(Response.@"404"());
        return;
    };
    defer file_handler.close();

    const file_content = try file_handler.readToEndAlloc(allocator, 1024 * 1024);

    const response = try Response.file(allocator, file_content);
    defer response.deinit();
    const bytes = try response.pack(&request.headers);
    defer allocator.free(bytes);

    _ = try stream.write(bytes);
}

fn do(allocator: std.mem.Allocator, conn: std.net.Server.Connection) !void {
    var reader = conn.stream.reader();

    const request = try readRequest(allocator, &reader);
    defer request.deinit();

    if (std.mem.eql(u8, request.target, "/")) {
        switch (request.method) {
            Method.GET => _ = try conn.stream.write("HTTP/1.1 200 OK\r\n\r\n"),
            Method.POST => _ = try conn.stream.write(Response.@"404"()),
        }
    } else if (std.mem.startsWith(u8, request.target, "/echo")) {
        switch (request.method) {
            Method.GET => return echo(allocator, request, conn.stream),
            Method.POST => _ = try conn.stream.write(Response.@"404"()),
        }
    } else if (std.mem.startsWith(u8, request.target, "/user-agent")) {
        switch (request.method) {
            Method.GET => return userAgent(allocator, request, conn.stream),
            Method.POST => _ = try conn.stream.write(Response.@"404"()),
        }
    } else if (std.mem.startsWith(u8, request.target, "/files")) {
        switch (request.method) {
            Method.GET => return getFile(allocator, request, conn.stream),
            Method.POST => return postFile(request, conn.stream),
        }
    } else {
        _ = try conn.stream.write(Response.@"404"());
    }
}

fn handleConnection(allocator: std.mem.Allocator, conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    do(allocator, conn) catch {
        _ = conn.stream.write(Response.@"500"()) catch {};
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
