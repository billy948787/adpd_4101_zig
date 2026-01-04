const std = @import("std");
const linux = @import("std").os.linux;
const sensor = @import("sensors/sensor.zig");
const i2c = @import("utils/i2c.zig");

pub fn main() !void {
    var adpd4101_sensor = sensor.ADPD4101Sensor.init("/dev/i2c-3") catch |err| {
        std.debug.print("Failed to initialize ADPD4101 sensor: {}\n", .{err});
        return err;
    };

    defer adpd4101_sensor.deinit();

    _ = try adpd4101_sensor.read_raw();
}
