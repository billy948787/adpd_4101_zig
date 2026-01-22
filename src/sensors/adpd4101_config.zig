const adpd = @import("adpd4101.zig");
const gpio = @import("../utils/gpio.zig");

pub const oscillator = adpd.Oscillator.INTERNAL_1MHZ;
pub const timeslot_freq_hz: u32 = 100;
pub const i2c_device_path = "/dev/i2c-3";
pub const device_address: u8 = 0x24;
pub const use_ext_clock = false;
pub const gpio_id: u32 = 0;
pub const fifo_threshold: u16 = 4;
pub const time_slots = [_]adpd.TimeSlot{
    .{
        .id = "A",
        .leds = &[_]adpd.Led{
            .{
                .id = adpd.get_led_id("1A"),
                .current = 0x07f,
            },
        },
        .data_format = .{
            .lit_size = 0x0,
            .sig_size = 0x4,
            .dark_size = 0x0,
        }, // default
        .led_pulse = .{
            .pulse_width_us = 0x2,
        }, // default
        .input_config = .{
            .pair_12 = .IN1_Ch1,
        },
        .counts = .{
            .num_integrations = 0x2,
            .num_repeats = 0x8,
        },
        .mod_pulse = .{},
        .cathode = .{
            .vc1_select = .TIA_VREF_PLUS_215mV,
            .precondition = .TIA_VREF,
        },
    },
};
