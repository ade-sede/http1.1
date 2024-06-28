const std = @import("std");
// Uncomment this block to pass the first stage
// const net = std.net;

pub fn main() !void {
    const address = try std.net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    var conn = try listener.accept();

    _ = try conn.stream.write("HTTP/1.1 200 OK\r\n\r\n");
}
