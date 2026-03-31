const adpd = @import("adpd4101.zig");
const gpio = @import("../utils/gpio.zig");

pub const oscillator = adpd.Oscillator.INTERNAL_1MHZ;
pub const timeslot_freq_hz: u32 = 100;
pub const i2c_device_path = "/dev/i2c-3";
pub const device_address: u8 = 0x24;
pub const use_ext_clock = false;
pub const gpio_id: u32 = 0;
pub const fifo_threshold: u16 = 20;
pub const fifo_status_sum_enable = true;
pub const time_slots = [_]adpd.TimeSlot{
    .{
        .id = "A",
        .leds = &[_]adpd.Led{
            .{
                .id = adpd.get_led_id("1A"),
                .current = 0x3f,
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
            .num_integrations = 0x1,
            .num_repeats = 0x32,
        },
        .mod_pulse = .{},
        .cathode = .{
            .vc1_select = .TIA_VREF_PLUS_215mV,
            .precondition = .TIA_VREF,
        },
        .afe_trim = .{
            .tia_ceil_detect = 1,
            .tia_gain_ch1 = .KOHM12_5,
        },
        .pattern = .{
            .subtract = 0xA,
            .reverse_integration = 0xA,
        },
        .adc_offset1 = .{},
        .adc_offset2 = .{
            .zero_adjust = 1,
        },
        .timeslot_ctrl = .{
            .input_resister_select = .KOHM_6_5,
        },
        .integrate_offset = .{
            // .integrate_offset_1_US = 0xD6,
            // .integrate_offset_31_25_NS = 0x16,
        },
    },
    .{
        .id = "B",
        .leds = &[_]adpd.Led{
            .{
                .id = adpd.get_led_id("2A"),
                .current = 0x3f,
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
            .num_integrations = 0x1,
            .num_repeats = 0x32,
        },
        .mod_pulse = .{},
        .cathode = .{
            .vc1_select = .TIA_VREF_PLUS_215mV,
            .precondition = .TIA_VREF,
        },
        .afe_trim = .{
            .tia_ceil_detect = 1,
            .tia_gain_ch1 = .KOHM12_5,
        },
        .pattern = .{
            .subtract = 0xA,
            .reverse_integration = 0xA,
        },
        .adc_offset1 = .{},
        .adc_offset2 = .{
            .zero_adjust = 1,
        },
        .timeslot_ctrl = .{
            .input_resister_select = .KOHM_6_5,
        },
        .integrate_offset = .{
            // .integrate_offset_1_US = 0xD6,
            // .integrate_offset_31_25_NS = 0x16,
        },
    },
    .{
        .id = "C",
        .leds = &[_]adpd.Led{
            .{
                .id = adpd.get_led_id("3A"),
                .current = 0x3f,
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
            .num_integrations = 0x1,
            .num_repeats = 0x32,
        },
        .mod_pulse = .{},
        .cathode = .{
            .vc1_select = .TIA_VREF_PLUS_215mV,
            .precondition = .TIA_VREF,
        },
        .afe_trim = .{
            .tia_ceil_detect = 1,
            .tia_gain_ch1 = .KOHM12_5,
        },
        .pattern = .{
            .subtract = 0xA,
            .reverse_integration = 0xA,
        },
        .adc_offset1 = .{},
        .adc_offset2 = .{
            .zero_adjust = 1,
        },
        .timeslot_ctrl = .{
            .input_resister_select = .KOHM_6_5,
        },
        .integrate_offset = .{
            // .integrate_offset_1_US = 0xD6,
            // .integrate_offset_31_25_NS = 0x16,
        },
    },
    .{
        .id = "D",
        .leds = &[_]adpd.Led{
            .{
                .id = adpd.get_led_id("4A"),
                .current = 0x3f,
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
            .num_integrations = 0x1,
            .num_repeats = 0x32,
        },
        .mod_pulse = .{},
        .cathode = .{
            .vc1_select = .TIA_VREF_PLUS_215mV,
            .precondition = .TIA_VREF,
        },
        .afe_trim = .{
            .tia_ceil_detect = 1,
            .tia_gain_ch1 = .KOHM12_5,
        },
        .pattern = .{
            .subtract = 0xA,
            .reverse_integration = 0xA,
        },
        .adc_offset1 = .{},
        .adc_offset2 = .{
            .zero_adjust = 1,
        },
        .timeslot_ctrl = .{
            .input_resister_select = .KOHM_6_5,
        },
        .integrate_offset = .{
            // .integrate_offset_1_US = 0xD6,
            // .integrate_offset_31_25_NS = 0x16,
        },
    },
    .{
        .id = "E",
        .leds = &[_]adpd.Led{
            .{
                .id = adpd.get_led_id("1B"),
                .current = 0x3f,
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
            .num_integrations = 0x1,
            .num_repeats = 0x32,
        },
        .mod_pulse = .{},
        .cathode = .{
            .vc1_select = .TIA_VREF_PLUS_215mV,
            .precondition = .TIA_VREF,
        },
        .afe_trim = .{
            .tia_ceil_detect = 1,
            .tia_gain_ch1 = .KOHM12_5,
        },
        .pattern = .{
            .subtract = 0xA,
            .reverse_integration = 0xA,
        },
        .adc_offset1 = .{},
        .adc_offset2 = .{
            .zero_adjust = 1,
        },
        .timeslot_ctrl = .{
            .input_resister_select = .KOHM_6_5,
        },
        .integrate_offset = .{
            // .integrate_offset_1_US = 0xD6,
            // .integrate_offset_31_25_NS = 0x16,
        },
    },
};
