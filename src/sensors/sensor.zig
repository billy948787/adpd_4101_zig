const std = @import("std");

pub fn Sensor(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "init")) @compileError("The struct need implement init");
        if (!@hasDecl(T, "deinit")) @compileError("The struct need implement deinit");
        if (!@hasDecl(T, "read_raw")) @compileError("The struct need implement read_raw");
    }

    return T;
}

pub var ADPDSensor = Sensor(@import("adpd4101.zig").ADPD4101("/dev/i2c-3"));
