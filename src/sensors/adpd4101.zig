const i2c = @import("../utils/i2c.zig");
const std = @import("std");

pub const ADPD4101 = struct {
    fd: std.posix.fd_t,

    pub fn init(i2c_bus_path: []const u8) !ADPD4101 {
        const file = try std.fs.cwd().openFile(i2c_bus_path, .{ .mode = .read_write });
        return ADPD4101{
            .fd = file.handle,
        };
    }

    pub fn deinit(self: *ADPD4101) void {
        std.posix.close(self.fd);
    }

    pub fn read_raw(self: *const ADPD4101) ![2]u8 {
        return i2c.I2cReadReg(self.fd, DEV_ADDR, FIFO_DATA_REG);
    }
};

fn set_opmode(fd: std.posix.fd_t, slot_count: u8, is_enable: bool) !void {
    var mode: u16 = if (is_enable) 0b0000_0001 else 0b0000_0000;

    mode |= u16(slot_count - 1) << 8;

    i2c.i2cWriteReg(fd, DEV_ADDR, OPMODE_REG, @as([2]u8, mode));
}

fn set_oscillator(
    fd: std.posix.fd_t,
    oscillator: Oscillator,
    use_ext_clock: bool,
) !void {
    if (use_ext_clock) {
        unreachable;
    }

    const sys_ctl: u16 = switch (oscillator) {
        .INTERNAL_1MHZ => 0b0000_0101,
        .INTERNAL_32KHZ => 0b0000_0000,
    };

    i2c.i2cWriteReg(fd, DEV_ADDR, SYS_CTL_REG, @as([2]u8, sys_ctl));
}

// compile time function to get LED ID from name
fn get_led_id(comptime names: [][]const u8) [][]const u16 {
    comptime {
        var result: [names.len]u16 = undefined;
        for (names, 0..) |name, i| {
            if (name.len != 2) {
                @compileError("LED name must be 2 characters long");
            }
            const number = name[0] - '0' - 1;
            const letter = name[1];

            result[i] = (number * 2 + (letter - 'A'));
        }
        return result;
    }
}
// ADPD4101 Constants
const SLOT_COUNT: u8 = 1;
const USE_EXT_CLOCK: bool = false;
const LED_IDS: []const []u8 = get_led_id(&[_][]const u8{
    "1A",
});

// Device I2C Address
const DEV_ADDR: u8 = 0x24;

// Register Addresses
const OPMODE_REG: u16 = 0x0010;
const SYS_CTL_REG: u16 = 0x000F;
const FIFO_STATUS_REG: u16 = 0x0000;
const FIFO_DATA_REG: u16 = 0x002F;
const LED_POW12_A_REG: u16 = 0x0105;
const LED_POW12_B_REG: u16 = 0x0125;
const LED_POW12_C_REG: u16 = 0x0145;
const LED_POW12_D_REG: u16 = 0x0165;
const LED_POW12_E_REG: u16 = 0x0185;

const Oscillator = enum { INTERNAL_1MHZ, INTERNAL_32KHZ };
