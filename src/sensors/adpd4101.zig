const i2c = @import("../utils/i2c.zig");
const std = @import("std");
const regs = @import("adpd4101_reg.zig");

pub const ADPD4101 = struct {
    fd: std.posix.fd_t,
    dev_addr: u8,
    buffer: [1024]u8 = undefined,

    pub fn init(
        comptime i2c_bus_path: []const u8,
        comptime dev_addr: u8,
        comptime oscillator: Oscillator,
        comptime timeslot_freq_hz: u32,
        comptime timeslots: []const TimeSlot,
        comptime use_ext_clock: bool,
        comptime fifo_threshold: u16,
        comptime gpio_id: u32,
    ) !ADPD4101 {
        const file = try std.fs.cwd().openFile(i2c_bus_path, .{ .mode = .read_write });

        const fd = file.handle;

        try reset_all(fd, dev_addr);

        try set_oscillator(fd, dev_addr, oscillator, use_ext_clock);
        inline for (timeslots) |ts| {
            try config_time_slot(fd, dev_addr, ts);
        }
        try set_interrupt(fd, dev_addr, gpio_id, fifo_threshold);
        try set_time_slot_freq(fd, dev_addr, oscillator, timeslot_freq_hz);
        try set_opmode(fd, dev_addr, @intCast(timeslots.len), true);
        return ADPD4101{
            .fd = fd,
            .dev_addr = dev_addr,
        };
    }

    pub fn deinit(self: *ADPD4101) void {
        reset_all(self.fd, self.dev_addr) catch {
            // stderr.print("Failed to reset ADPD4101 during deinit: {}\n", .{err}) catch {};
        };
        std.posix.close(self.fd);
    }

    pub fn read_raw(self: *ADPD4101) ![]const u8 {
        // get fifo status
        const status = try i2c.I2cReadReg(self.fd, self.dev_addr, FIFO_STATUS_REG);
        // // std.debug.print("FIFO_STATUS_REG: {any}\n", .{status});
        const fifo_size: u16 = std.mem.readInt(u16, &status, .big) & 0b0000_0111_1111_1111;
        // // std.debug.print("FIFO size: {d}\n", .{fifo_size});
        if (fifo_size == 0) {
            return &[_]u8{};
        }

        const to_read: usize = @min(@as(usize, fifo_size), self.buffer.len);

        try i2c.i2cKeepReadReg(self.fd, self.dev_addr, FIFO_DATA_REG, self.buffer[0..to_read]);

        return self.buffer[0..to_read];
    }
};

fn set_opmode(fd: std.posix.fd_t, dev_addr: u8, slot_count: u8, is_enable: bool) !void {
    const mode_value = regs.OpModeReg{
        .opmode_enable = @intFromBool(is_enable),
        .timeslot_enable = @truncate(slot_count - 1),
        .reserved = 0,
        .reserved2 = 0,
    };

    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, @bitCast(mode_value), .big);
    try i2c.i2cWriteReg(fd, dev_addr, OPMODE_REG, @as([2]u8, data));
}

fn set_interrupt(fd: std.posix.fd_t, dev_addr: u8, gpio_id: u32, comptime fifo_threshold: u16) !void {
    comptime {
        if (fifo_threshold > 0x01FF) {
            @compileError("FIFO threshold must be less than or equal to 511");
        }
    }

    var data: [2]u8 = undefined;
    // set interrupt threshold for fifo
    std.mem.writeInt(u16, &data, fifo_threshold, .big);
    try i2c.i2cWriteReg(fd, dev_addr, FIFO_TH_REG, @as([2]u8, data));

    // set interrupt path to x
    const int_enable_x: u16 = 0b1000_0000_0000_0000;
    const target_gpio_reg = if (gpio_id < 2) GPIO_01_REG else GPIO_23_REG;

    std.mem.writeInt(u16, &data, int_enable_x, .big);
    try i2c.i2cWriteReg(fd, dev_addr, INT_ENABLE_XD_REG, @as([2]u8, data));
    // enable the gpio
    const enable_value: u16 = 0b010;
    // read the original gpio config

    var gpio_cfg_data = try i2c.I2cReadReg(fd, dev_addr, GPIO_CFG_REG);

    var gpio_cfg_reg: regs.GpioConfigReg = @bitCast(std.mem.readInt(u16, &gpio_cfg_data, .big));

    switch (gpio_id) {
        0 => gpio_cfg_reg.gpio_pin_config0 = enable_value,
        1 => gpio_cfg_reg.gpio_pin_config1 = enable_value,
        2 => gpio_cfg_reg.gpio_pin_config2 = enable_value,
        3 => gpio_cfg_reg.gpio_pin_config3 = enable_value,
        else => unreachable,
    }
    // write back the gpio config
    std.mem.writeInt(u16, &data, @bitCast(gpio_cfg_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, GPIO_CFG_REG, @as([2]u8, data));

    // config the gpio output
    // 0x02 mean interrupt x
    const gpio_set_value: u16 = 0x02;
    const gpio_value_reg = regs.GpioReg{
        .gpio_out_1 = if (gpio_id % 2 == 0) gpio_set_value else 0,
        .gpio_out_2 = if (gpio_id % 2 == 1) gpio_set_value else 0,
        .reserved = 0,
        .reserved2 = 0,
    };
    std.mem.writeInt(u16, &data, @bitCast(gpio_value_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, target_gpio_reg, @as([2]u8, data));
}

fn reset_all(fd: std.posix.fd_t, dev_addr: u8) !void {
    const data: [2]u8 = [_]u8{ 0b10000000, 0x00 };
    try i2c.i2cWriteReg(fd, dev_addr, SYS_CTL_REG, data);
}

fn set_oscillator(
    fd: std.posix.fd_t,
    dev_addr: u8,
    oscillator: Oscillator,
    use_ext_clock: bool,
) !void {
    if (use_ext_clock) {
        unreachable;
    }
    const sys_ctl_reg = regs.SysCtlReg{
        .software_reset = 0,
        .reserved2 = 0,
        .reserved = 0,
        .internal_1MHZoscillator_enable = if (oscillator == .INTERNAL_1MHZ) 1 else 0,
        .internal_32kHz_oscillator_enable = if (oscillator == .INTERNAL_32KHZ) 1 else 0,
        .alternate_clock_select = 0,
        .alternate_clock_gpio_select = 0,
        .low_frequency_oscillator_select = 1,
    };

    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, @bitCast(sys_ctl_reg), .big);

    try i2c.i2cWriteReg(fd, dev_addr, SYS_CTL_REG, @as([2]u8, data));
}

fn config_time_slot(fd: std.posix.fd_t, dev_addr: u8, comptime slot: TimeSlot) !void {
    const input_target_reg = INPUT_A_REG + (slot.id[0] - 'A') * 0x20;
    const ts_ctrl_target_reg = TS_CTRL_A_REG + (slot.id[0] - 'A') * 0x20;
    const data_format_target_reg = DATA_FORMAT_A_REG + (slot.id[0] - 'A') * 0x20;
    const lit_data_format_target_reg = LIT_DATA_FORMAT_A_REG + (slot.id[0] - 'A') * 0x20;
    const mod_pulse_target_reg = MOD_PULSE_A_REG + (slot.id[0] - 'A') * 0x20;
    const led_pow12_target_reg = LED_POW12_A_REG + (slot.id[0] - 'A') * 0x20;
    const led_pow34_target_reg = LED_POW34_A_REG + (slot.id[0] - 'A') * 0x20;
    const counts_target_reg = COUNTS_A_REG + (slot.id[0] - 'A') * 0x20;
    // buffer
    var data: [2]u8 = undefined;

    const input_reg = regs.InputReg{
        .INP12 = @intFromEnum(slot.input_config.pair_12),
        .INP34 = @intFromEnum(slot.input_config.pair_34),
        .INP56 = @intFromEnum(slot.input_config.pair_56),
        .INP78 = @intFromEnum(slot.input_config.pair_78),
    };

    const ch2_enabled = slot.input_config.pair_12 == .IN1_Ch2 or
        slot.input_config.pair_12 == .IN2_Ch2 or
        slot.input_config.pair_12 == .IN1_Ch1_IN2_Ch2 or
        slot.input_config.pair_12 == .IN1_Ch2_IN2_Ch1 or
        slot.input_config.pair_12 == .Both_Ch2 or
        slot.input_config.pair_34 == .IN1_Ch2 or
        slot.input_config.pair_34 == .IN2_Ch2 or
        slot.input_config.pair_34 == .IN1_Ch1_IN2_Ch2 or
        slot.input_config.pair_34 == .IN1_Ch2_IN2_Ch1 or
        slot.input_config.pair_34 == .Both_Ch2 or
        slot.input_config.pair_56 == .IN1_Ch2 or
        slot.input_config.pair_56 == .IN2_Ch2 or
        slot.input_config.pair_56 == .IN1_Ch1_IN2_Ch2 or
        slot.input_config.pair_56 == .IN1_Ch2_IN2_Ch1 or
        slot.input_config.pair_56 == .Both_Ch2 or
        slot.input_config.pair_78 == .IN1_Ch2 or
        slot.input_config.pair_78 == .IN2_Ch2 or
        slot.input_config.pair_78 == .IN1_Ch1_IN2_Ch2 or
        slot.input_config.pair_78 == .IN1_Ch2_IN2_Ch1 or
        slot.input_config.pair_78 == .Both_Ch2;

    const ts_ctrl_reg = regs.TsCtrlReg{
        .ch2_enable = @intFromBool(ch2_enabled),
        .subsample = 0,
        .sample_type = 0,
        .input_resister_select = 0,
        .timeslot_offset = 0,
    };

    std.mem.writeInt(u16, &data, @bitCast(input_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, input_target_reg, @as([2]u8, data));
    std.mem.writeInt(u16, &data, @bitCast(ts_ctrl_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, ts_ctrl_target_reg, @as([2]u8, data));

    const data_format_reg = regs.DataFormatReg{
        .dark_shift = slot.data_format.dark_shift,
        .dark_size = slot.data_format.dark_size,
        .sig_shift = slot.data_format.sig_shift,
        .sig_size = slot.data_format.sig_size,
    };

    std.mem.writeInt(u16, &data, @bitCast(data_format_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, data_format_target_reg, @as([2]u8, data));

    const lit_data_format_reg = regs.LitDataFormatReg{
        .reserved = 0,
        .lit_shift = slot.data_format.lit_shift,
        .lit_size = slot.data_format.lit_size,
    };

    std.mem.writeInt(u16, &data, @bitCast(lit_data_format_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, lit_data_format_target_reg, @as([2]u8, data));

    const mod_pulse_reg = regs.ModPulseReg{
        .pulse_offset = slot.mod_pulse.mod_offset,
        .pulse_width = slot.mod_pulse.mod_width,
    };

    std.mem.writeInt(u16, &data, @bitCast(mod_pulse_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, mod_pulse_target_reg, @as([2]u8, data));

    var led_pow12_reg: regs.LedPowerReg = regs.LedPowerReg{
        .led1_driveside = 0,
        .led1_current = 0,
        .led2_driveside = 0,
        .led2_current = 0,
    };
    var led_pow34_reg: regs.LedPowerReg = regs.LedPowerReg{
        .led1_driveside = 0,
        .led1_current = 0,
        .led2_driveside = 0,
        .led2_current = 0,
    };

    // configure LED power
    for (slot.leds) |led| {
        const current: u7 = @min(led.current, 0x7F);

        switch (led.id / 2) {
            0 => {
                led_pow12_reg.led1_current = @truncate(current);
                led_pow12_reg.led1_driveside = @truncate(led.id % 2);
            },
            1 => {
                led_pow12_reg.led2_current = @truncate(current);
                led_pow12_reg.led2_driveside = @truncate(led.id % 2);
            },
            2 => {
                led_pow34_reg.led1_current = @truncate(current);
                led_pow34_reg.led1_driveside = @truncate(led.id % 2);
            },
            3 => {
                led_pow34_reg.led2_current = @truncate(current);
                led_pow34_reg.led2_driveside = @truncate(led.id % 2);
            },
            else => unreachable,
        }
    }

    std.mem.writeInt(u16, &data, @bitCast(led_pow12_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, led_pow12_target_reg, @as([2]u8, data));
    std.mem.writeInt(u16, &data, @bitCast(led_pow34_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, led_pow34_target_reg, @as([2]u8, data));

    // configure counts
    const counts_reg = regs.CountReg{
        .num_integrations = slot.counts.num_integrations,
        .num_repeats = slot.counts.num_repeats,
    };
    std.mem.writeInt(u16, &data, @bitCast(counts_reg), .big);
    try i2c.i2cWriteReg(fd, dev_addr, counts_target_reg, @as([2]u8, data));
}

fn set_time_slot_freq(fd: std.posix.fd_t, dev_addr: u8, oscillator: Oscillator, target_hz: u32) !void {
    const oscillator_freq: u32 = switch (oscillator) {
        .INTERNAL_1MHZ => 1_000_000,
        .INTERNAL_32KHZ => 32_768,
    };

    const ts_freq: u32 = oscillator_freq / target_hz;
    const low_freq: u16 = @truncate(ts_freq & 0x0000FFFF);
    const high_freq: u16 = @truncate((ts_freq >> 16) & 0xFFFF);

    // std.debug.print("Setting time slot frequency to {any} Hz (low_freq: {x}, high_freq: {x})\n", .{ target_hz, low_freq, high_freq });

    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, low_freq, .big);
    // std.debug.print("Setting TS_FREQ to {any}\n", .{data});
    try i2c.i2cWriteReg(fd, dev_addr, TS_FREQ_REG, @as([2]u8, data));
    std.mem.writeInt(u16, &data, high_freq, .big);
    // std.debug.print("Setting TS_FREQH to {any}\n", .{data});
    try i2c.i2cWriteReg(fd, dev_addr, TS_FREQH_REG, @as([2]u8, data));
}

// compile time function to get LED ID from name
pub fn get_led_id(comptime name: []const u8) u16 {
    comptime {
        if (name.len != 2) {
            @compileError("LED name must be 2 characters long");
        }
        // to lower case
        if (name[1] < 'A' or name[1] > 'B') {
            @compileError("LED name second character must be A, B");
        }
        if (name[0] < '1' or name[0] > '4') {
            @compileError("LED name first character must be between 1 and 4");
        }
        const number = name[0] - '0' - 1;
        const letter = name[1];
        return (number * 2 + (letter - 'A'));
    }
}

// Register Addresses
// global control registers
const OPMODE_REG: u16 = 0x0010;
const SYS_CTL_REG: u16 = 0x000F;
const FIFO_STATUS_REG: u16 = 0x0000;
const FIFO_DATA_REG: u16 = 0x002F;
const TS_FREQ_REG: u16 = 0x000D;
const TS_FREQH_REG: u16 = 0x000E;
const FIFO_TH_REG: u16 = 0x0006;
const INT_ENABLE_XD_REG: u16 = 0x0014;
const INT_ENABLE_YD_REG: u16 = 0x0015;
// LED Power Registers
const LED_POW12_A_REG: u16 = 0x0105;
const LED_POW12_B_REG: u16 = 0x0125;
const LED_POW12_C_REG: u16 = 0x0145;
const LED_POW12_D_REG: u16 = 0x0165;
const LED_POW12_E_REG: u16 = 0x0185;
const LED_POW12_F_REG: u16 = 0x01A5;
const LED_POW12_G_REG: u16 = 0x01C5;
const LED_POW12_H_REG: u16 = 0x01E5;
const LED_POW12_I_REG: u16 = 0x0205;
const LED_POW12_J_REG: u16 = 0x0225;
const LED_POW12_K_REG: u16 = 0x0245;
const LED_POW12_L_REG: u16 = 0x0265;
const LED_POW34_A_REG: u16 = 0x0106;
const LED_POW34_B_REG: u16 = 0x0126;
const LED_POW34_C_REG: u16 = 0x0146;
const LED_POW34_D_REG: u16 = 0x0166;
const LED_POW34_E_REG: u16 = 0x0186;
const LED_POW34_F_REG: u16 = 0x01A6;
const LED_POW34_G_REG: u16 = 0x01C6;
const LED_POW34_H_REG: u16 = 0x01E6;
const LED_POW34_I_REG: u16 = 0x0206;
const LED_POW34_J_REG: u16 = 0x0226;
const LED_POW34_K_REG: u16 = 0x0246;
const LED_POW34_L_REG: u16 = 0x0266;
// input register
const INPUT_A_REG: u16 = 0x0102;
const INPUT_B_REG: u16 = 0x0122;
const INPUT_C_REG: u16 = 0x0142;
const INPUT_D_REG: u16 = 0x0162;
const INPUT_E_REG: u16 = 0x0182;
const INPUT_F_REG: u16 = 0x01A2;
const INPUT_G_REG: u16 = 0x01C2;
const INPUT_H_REG: u16 = 0x01E2;
const INPUT_I_REG: u16 = 0x0202;
const INPUT_J_REG: u16 = 0x0222;
const INPUT_K_REG: u16 = 0x0242;
const INPUT_L_REG: u16 = 0x0262;
// ts ctrl register
const TS_CTRL_A_REG: u16 = 0x0100;
const TS_CTRL_B_REG: u16 = 0x0120;
const TS_CTRL_C_REG: u16 = 0x0140;
const TS_CTRL_D_REG: u16 = 0x0160;
const TS_CTRL_E_REG: u16 = 0x0180;
const TS_CTRL_F_REG: u16 = 0x01A0;
const TS_CTRL_G_REG: u16 = 0x01C0;
const TS_CTRL_H_REG: u16 = 0x01E0;
const TS_CTRL_I_REG: u16 = 0x0200;
const TS_CTRL_J_REG: u16 = 0x0220;
const TS_CTRL_K_REG: u16 = 0x0240;
const TS_CTRL_L_REG: u16 = 0x0260;
// ts pulse register
const MOD_PULSE_A_REG: u16 = 0x010C;
const MOD_PULSE_B_REG: u16 = 0x012C;
const MOD_PULSE_C_REG: u16 = 0x014C;
const MOD_PULSE_D_REG: u16 = 0x016C;
const MOD_PULSE_E_REG: u16 = 0x018C;
const MOD_PULSE_F_REG: u16 = 0x01AC;
const MOD_PULSE_G_REG: u16 = 0x01CC;
const MOD_PULSE_H_REG: u16 = 0x01EC;
const MOD_PULSE_I_REG: u16 = 0x020C;
const MOD_PULSE_J_REG: u16 = 0x022C;
const MOD_PULSE_K_REG: u16 = 0x024C;
const MOD_PULSE_L_REG: u16 = 0x026C;
// data format register
const DATA_FORMAT_A_REG: u16 = 0x0110;
const DATA_FORMAT_B_REG: u16 = 0x0130;
const DATA_FORMAT_C_REG: u16 = 0x0150;
const DATA_FORMAT_D_REG: u16 = 0x0170;
const DATA_FORMAT_E_REG: u16 = 0x0190;
const DATA_FORMAT_F_REG: u16 = 0x01B0;
const DATA_FORMAT_G_REG: u16 = 0x01D0;
const DATA_FORMAT_H_REG: u16 = 0x01F0;
const DATA_FORMAT_I_REG: u16 = 0x0210;
const DATA_FORMAT_J_REG: u16 = 0x0230;
const DATA_FORMAT_K_REG: u16 = 0x0250;
const DATA_FORMAT_L_REG: u16 = 0x0270;
const LIT_DATA_FORMAT_A_REG: u16 = 0x0111;
const LIT_DATA_FORMAT_B_REG: u16 = 0x0131;
const LIT_DATA_FORMAT_C_REG: u16 = 0x0151;
const LIT_DATA_FORMAT_D_REG: u16 = 0x0171;
const LIT_DATA_FORMAT_E_REG: u16 = 0x0191;
const LIT_DATA_FORMAT_F_REG: u16 = 0x01B1;
const LIT_DATA_FORMAT_G_REG: u16 = 0x01D1;
const LIT_DATA_FORMAT_H_REG: u16 = 0x01F1;
const LIT_DATA_FORMAT_I_REG: u16 = 0x0211;
const LIT_DATA_FORMAT_J_REG: u16 = 0x0231;
const LIT_DATA_FORMAT_K_REG: u16 = 0x0251;
const LIT_DATA_FORMAT_L_REG: u16 = 0x0271;
// counts register
const COUNTS_A_REG: u16 = 0x0107;
const COUNTS_B_REG: u16 = 0x0127;
const COUNTS_C_REG: u16 = 0x0147;
const COUNTS_D_REG: u16 = 0x0167;
const COUNTS_E_REG: u16 = 0x0187;
const COUNTS_F_REG: u16 = 0x01A7;
const COUNTS_G_REG: u16 = 0x01C7;
const COUNTS_H_REG: u16 = 0x01E7;
const COUNTS_I_REG: u16 = 0x0207;
const COUNTS_J_REG: u16 = 0x0227;
const COUNTS_K_REG: u16 = 0x0247;
const COUNTS_L_REG: u16 = 0x0267;
// gpio register
const GPIO_CFG_REG: u16 = 0x0022;
const GPIO_01_REG: u16 = 0x0023;
const GPIO_23_REG: u16 = 0x0024;

pub const Oscillator = enum { INTERNAL_1MHZ, INTERNAL_32KHZ };

// struct definitions
pub const TimeSlot = struct {
    id: []const u8,
    leds: []const Led,
    counts: Counts,
    data_format: DataFormat,
    led_pulse: LedPulse,
    input_config: InputConfig,
    mod_pulse: ModPulse,
};

pub const InputPairMode = enum(u4) {
    Disabled = 0b0000,
    IN1_Ch1 = 0b0001,
    IN1_Ch2 = 0b0010,
    IN2_Ch1 = 0b0011,
    IN2_Ch2 = 0b0100,
    IN1_Ch1_IN2_Ch2 = 0b0101,
    IN1_Ch2_IN2_Ch1 = 0b0110,
    Both_Ch1 = 0b0111,
    Both_Ch2 = 0b1000,
};

pub const InputConfig = struct {
    pair_12: InputPairMode = .Disabled,
    pair_34: InputPairMode = .Disabled,
    pair_56: InputPairMode = .Disabled,
    pair_78: InputPairMode = .Disabled,
};

pub const DataFormat = struct {
    dark_shift: u8 = 0x0,
    dark_size: u8 = 0x0,
    lit_shift: u8 = 0x0,
    lit_size: u8 = 0x3,
    sig_shift: u8 = 0x0,
    sig_size: u8 = 0x3,
};

pub const Counts = struct {
    num_integrations: u16 = 0x1,
    num_repeats: u16 = 0x1,
};

pub const Led = struct {
    id: u16,
    current: u16,
};

pub const LedPulse = struct {
    pulse_width_us: u16 = 0x2,
    pulse_offset_us: u16 = 0x10,
};

pub const ModPulse = struct {
    mod_width: u16 = 0x0,
    mod_offset: u16 = 0x1,
};
pub const PD = struct {
    id: u16,
};
