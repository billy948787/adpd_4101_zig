const gpio = @import("utils/gpio.zig");

pub const interrupt_gpio_pin_id = gpio.get_gpio_id(1, 'C', 4);
