pub const LedPowerReg = packed struct(u16) {
    led1_current: u7,
    led1_driveside: u1,
    led2_current: u7,
    led2_driveside: u1,
};

pub const LedPulseReg = packed struct(u16) {
    pulse_offset: u8,
    pulse_width: u8,
};

pub const CountReg = packed struct(u16) {
    num_repeats: u8,
    num_integrations: u8,
};

pub const ModPulseReg = packed struct(u16) {
    pulse_offset: u8,
    pulse_width: u8,
};

pub const DataFormatReg = packed struct(u16) {
    sig_size: u3,
    sig_shift: u5,
    dark_size: u3,
    dark_shift: u5,
};

pub const LitDataFormatReg = packed struct(u16) {
    lit_size: u3,
    lit_shift: u5,
    reserved: u8,
};

pub const InputReg = packed struct(u16) {
    INP12: u4,
    INP34: u4,
    INP56: u4,
    INP78: u4,
};

pub const TsCtrlReg = packed struct(u16) {
    timeslot_offset: u10,
    input_resister_select: u2,
    sample_type: u2,
    ch2_enable: u1,
    subsample: u1,
};

pub const GpioReg = packed struct(u16) {
    gpio_out_1: u7,
    reserved2: u1,
    gpio_out_2: u7,
    reserved: u1,
};

pub const GpioConfigReg = packed struct(u16) {
    gpio_pin_config0: u3,
    gpio_pin_config1: u3,
    gpio_pin_config2: u3,
    gpio_pin_config3: u3,
    gpio_drv: u2,
    gpio_slew: u2,
};

pub const FifoThresholdReg = packed struct(u16) {
    fifo_threshold: u10,
    reserved: u6,
};

pub const OpModeReg = packed struct(u16) {
    opmode_enable: u1,
    reserved2: u7,
    timeslot_enable: u4,
    reserved: u4,
};

pub const SysCtlReg = packed struct(u16) {
    internal_32kHz_oscillator_enable: u1,
    internal_1MHZoscillator_enable: u1,
    low_frequency_oscillator_select: u1,
    reserved2: u3,
    alternate_clock_gpio_select: u2,
    alternate_clock_select: u2,
    reserved: u5,
    software_reset: u1,
};

pub const TimeslowFreqReg = packed struct(u16) {
    timeslot_frequency: u16,
};

pub const TimeslowFreqHighReg = packed struct(u16) {
    timeslot_frequency_high: u7,
    reserved: u9,
};
