const std = @import("std");

pub fn Sensor(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "init")) @compileError("The struct need implement init");
        if (!@hasDecl(T, "deinit")) @compileError("The struct need implement deinit");
        if (!@hasDecl(T, "read_raw")) @compileError("The struct need implement read_raw");
    }

    return T;
}

pub const ADPD4101Sensor = Sensor(@import("adpd4101.zig").ADPD4101);
