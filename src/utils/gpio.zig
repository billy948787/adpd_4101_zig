const std = @import("std");
const linux = @import("std").os.linux;

fn openWriteOnly(path: []const u8) !std.posix.fd_t {
    return std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY }, 0);
}

fn openReadWrite(path: []const u8) !std.posix.fd_t {
    return std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDWR }, 0);
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteFailed;
                written += n;
            },
            .INTR => {},
            .BUSY => return error.DeviceBusy,
            else => return error.WriteFailed,
        }
    }
}

pub fn get_gpio_id(comptime bank: u8, comptime group: u8, comptime number: u8) u32 {
    comptime {
        if (group < 'A' or group > 'D') @compileError("Group must be between 'A' and 'D'");
        if (bank > 4 or bank < 0) @compileError("Bank must be between 0 and 4");
        if (number > 7 or number < 0) @compileError("Number must be between 0 and 7");

        return (bank * 32 + ((group - 'A') * 8 + number));
    }
}

pub const GPIO = struct {
    pin_id: u32,
    fd: std.posix.fd_t,

    pub fn init(comptime pin_id: u32) !GPIO {
        // std.debug.print("Exported GPIO pin {d}\n", .{pin_id});
        const export_file = try openWriteOnly("/sys/class/gpio/export");
        defer _ = linux.close(export_file);

        var write_buf: [32]u8 = undefined;
        const slice_buf = std.fmt.bufPrint(&write_buf, "{d}\n", .{pin_id}) catch {
            return error.FmtError;
        };
        writeAllFd(export_file, slice_buf) catch |err| switch (err) {
            error.DeviceBusy => {},
            else => |e| return e,
        };

        // sleep for a short time to allow sysfs to create the gpio directory
        // std.Thread.sleep(100000000);

        var file_path_buf: [64]u8 = undefined;

        const input_path = std.fmt.bufPrint(&file_path_buf, "/sys/class/gpio/gpio{d}/value", .{pin_id}) catch {
            return error.FmtError;
        };

        const fd = try openReadWrite(input_path);

        // set the direction to input
        const direction_path = std.fmt.bufPrint(&file_path_buf, "/sys/class/gpio/gpio{d}/direction", .{pin_id}) catch {
            return error.FmtError;
        };
        const direction_file = try openWriteOnly(direction_path);
        defer _ = linux.close(direction_file);
        try writeAllFd(direction_file, "in\n");

        // set the edge to rising
        const edge_path = std.fmt.bufPrint(&file_path_buf, "/sys/class/gpio/gpio{d}/edge", .{pin_id}) catch {
            return error.FmtError;
        };
        const edge_file = try openWriteOnly(edge_path);
        defer _ = linux.close(edge_file);
        try writeAllFd(edge_file, "rising\n");

        return GPIO{
            .pin_id = pin_id,
            .fd = fd,
        };
    }

    pub fn deinit(self: *GPIO) !void {
        _ = linux.close(self.fd);
        const unexport_file = try openWriteOnly("/sys/class/gpio/unexport");
        defer _ = linux.close(unexport_file);

        var write_buf: [32]u8 = undefined;
        const slice_buf = std.fmt.bufPrint(&write_buf, "{d}\n", .{self.pin_id}) catch {
            return error.FmtError;
        };

        try writeAllFd(unexport_file, slice_buf);
    }

    pub fn waitForInterrupt(self: *GPIO) !void {
        var poll_fd = [_]linux.pollfd{.{
            .fd = self.fd,
            .events = std.os.linux.POLL.PRI | std.os.linux.POLL.ERR,
            .revents = 0,
        }};

        _ = linux.poll(&poll_fd, 1, -1);

        // Clear the interrupt by reading the value
        if (poll_fd[0].revents & std.posix.POLL.PRI != 0) {
            var buf: [8]u8 = undefined;
            if (@sizeOf(usize) == 4) {
                var offset: u64 = 0;
                _ = linux.llseek(self.fd, 0, &offset, linux.SEEK.SET);
            } else {
                _ = linux.lseek(self.fd, 0, linux.SEEK.SET);
            }

            _ = try std.posix.read(self.fd, &buf);
        }
    }
};
