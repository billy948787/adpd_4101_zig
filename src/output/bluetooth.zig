const std = @import("std");

// use classic bt
pub const BluetoothClassicOutput = struct {
    server_socket_fd: i32,
    client_socket_fd: ?i32,
    pub fn init() !BluetoothClassicOutput {
        const server_socket_fd = try std.posix.socket(std.os.linux.AF.BLUETOOTH, std.os.linux.SOCK.STREAM, BTPROTO_RFCOMM);

        errdefer std.posix.close(server_socket_fd);

        var loc_addr: sockaddr_rc = undefined;

        loc_addr.rc_family = std.os.linux.AF.BLUETOOTH;
        loc_addr.rc_bdaddr = bdaddr_t{ .b = [_]u8{0} ** 6 };

        const enable: i32 = 1;
        loc_addr.rc_channel = 1;
        try std.posix.setsockopt(server_socket_fd, std.os.linux.SOL.SOCKET, std.os.linux.SO.REUSEADDR, std.mem.asBytes(&enable));

        try std.posix.bind(server_socket_fd, @ptrCast(&loc_addr), @sizeOf(sockaddr_rc));

        try std.posix.listen(server_socket_fd, 1);

        return BluetoothClassicOutput{
            .server_socket_fd = server_socket_fd,
            .client_socket_fd = null,
        };
    }

    pub fn accept(self: *BluetoothClassicOutput) !void {
        var client_addr: sockaddr_rc = undefined;
        var optlen: std.os.linux.socklen_t = @sizeOf(sockaddr_rc);
        const client_fd = try std.posix.accept(self.server_socket_fd, @ptrCast(&client_addr), &optlen, 0);

        self.client_socket_fd = client_fd;
    }

    pub fn closeClient(self: *BluetoothClassicOutput) !void {
        if (self.client_socket_fd) |client_fd| {
            const linger_opt = linger{
                .l_onoff = 1,
                .l_linger = 0,
            };
            try std.posix.setsockopt(client_fd, std.os.linux.SOL.SOCKET, std.os.linux.SO.LINGER, std.mem.asBytes(&linger_opt));
            try std.posix.shutdown(client_fd, .both);
            std.posix.close(client_fd);
            self.client_socket_fd = null;
        }
    }

    pub fn write(self: *BluetoothClassicOutput, data: []const u8) !void {
        if (self.client_socket_fd == null) {
            return error.NoClientConnected;
        }
        var total_written: usize = 0;
        while (total_written < data.len) {
            const written = try std.posix.write(self.client_socket_fd.?, data[total_written..]);
            if (written == 0) {
                return error.ConnectionClosed;
            }
            total_written += written;
        }
    }

    pub fn deinit(self: *BluetoothClassicOutput) !void {
        if (self.client_socket_fd) |client_fd| {
            try std.posix.shutdown(client_fd, .both);
            std.posix.close(client_fd);
        }
        try std.posix.shutdown(self.server_socket_fd, .both);
        std.posix.close(self.server_socket_fd);
    }
};

const bdaddr_t = extern struct {
    b: [6]u8,
};

const sockaddr_rc = extern struct {
    rc_family: u16,
    rc_bdaddr: bdaddr_t,
    rc_channel: u8,
};

const linger = extern struct {
    l_onoff: i32,
    l_linger: i32,
};

const BTPROTO_RFCOMM = 3;
