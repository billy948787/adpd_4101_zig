const i2c = @import("utils/i2c.zig");
const std = @import("std");

pub fn ADPD4101(comptime i2c_bus_path: []const u8) type {
    return struct {
        var fd: std.posix.fd_t = undefined;

        pub fn init() !void {
            const file = try std.fs.cwd().openFile(i2c_bus_path, .{ .mode = .read_write });
            fd = file.handle;
        }

        pub fn deinit() void {
            std.posix.close(fd);
        }

        pub fn read_raw(reg_addr: u16) ![2]u8 {
            return try i2c.I2cReadReg(fd, reg_addr);
        }
    };
}
