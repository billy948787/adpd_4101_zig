const std = @import("std");
const linux = @import("std").os.linux;
const sensor = @import("sensors/sensor.zig");
const i2c = @import("utils/i2c.zig");

pub fn main() !void {
    var adpa_sensor = sensor.ADPDSensor;

    try adpa_sensor.init();
}
