const std = @import("std");
const linux = @import("std").os.linux;
const sensor = @import("sensors/sensor.zig");
const i2c = @import("utils/i2c.zig");
const adpd_config = @import("sensors/adpd4101_config.zig");
const gpio = @import("utils/gpio.zig");
const constant = @import("constant.zig");
const bluetooth_output = @import("output/bluetooth.zig");

const imu_cpp = @cImport({
    @cInclude("imu.h");
});

var queue_mutex = std.Thread.Mutex{};
var processed_data_queue_mutex = std.Thread.Mutex{};

var should_exit = std.atomic.Value(bool).init(false);
var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
var raw_data_queue: std.ArrayList(u8) = undefined;
var processed_data_queue: std.ArrayList(ProcessedData) = undefined;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

var need_stop = std.atomic.Value(bool).init(false);

fn handle_signal(signum: c_int) callconv(.c) void {
    _ = signum;
    should_exit.store(true, .seq_cst);
}

fn send_data() void {
    var bt_output = bluetooth_output.BluetoothClassicOutput.init() catch |err| {
        stderr.print("Error initializing Bluetooth output: {}\n", .{err}) catch {};
        return;
    };
    defer bt_output.deinit() catch |err| {
        stderr.print("Error deinitializing Bluetooth output: {}\n", .{err}) catch {};
    };

    while (!should_exit.load(.seq_cst)) {
        if (bt_output.client_socket_fd == null) {
            std.debug.print("Bluetooth server listening on channel 1, waiting for connection...\n", .{});
            need_stop.store(true, .seq_cst);
            bt_output.accept() catch |err| {
                stderr.print("Error accepting Bluetooth connection: {}\n", .{err}) catch {};
                return;
            };
            need_stop.store(false, .seq_cst);
            std.debug.print("Bluetooth client connected, ready to send data.\n", .{});
        }
        processed_data_queue_mutex.lock();
        if (processed_data_queue.items.len > 0) {
            const data = processed_data_queue.items;
            for (data) |item| {
                var buffer: [64]u8 = undefined;
                const written = std.fmt.bufPrint(&buffer, "{d},{d}\n", .{ item.ppg_value, item.timestamp_ms }) catch |err| {
                    stderr.print("Error formatting data for Bluetooth: {}\n", .{err}) catch {};
                    continue;
                };
                bt_output.write(written) catch |err| {
                    stderr.print("Error writing data to Bluetooth: {}\n", .{err}) catch {};
                    bt_output.closeClient() catch |close_err| {
                        stderr.print("Error closing Bluetooth client socket: {}\n", .{close_err}) catch {};
                    };
                    break;
                };
            }
            processed_data_queue.clearRetainingCapacity();
        }
        processed_data_queue_mutex.unlock();
    }
}

fn process_data_queue() void {
    var timeslot_signal_size_arr: [adpd_config.time_slots.len]usize = undefined;

    inline for (adpd_config.time_slots, 0..) |slot, i| {
        timeslot_signal_size_arr[i] = @intCast(slot.data_format.sig_size);
    }

    var current_slot_index: usize = 0;

    var sensor_active = true;

    while (!should_exit.load(.seq_cst)) {
        if (need_stop.load(.seq_cst)) {
            if (sensor_active) {
                sensor_active = false;
                std.debug.print("Sensor disabled, pausing data processing.\n", .{});
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        } else {
            if (!sensor_active) {
                sensor_active = true;
                std.debug.print("Sensor enabled, resuming data processing.\n", .{});
            }
        }
        queue_mutex.lock();
        defer queue_mutex.unlock();

        if (raw_data_queue.items.len > 0) {
            const data = raw_data_queue.items;
            var data_index: usize = 0;

            while (data_index < data.len) {
                const size = timeslot_signal_size_arr[current_slot_index];
                if (data_index + size > data.len) {
                    break;
                }
                const signal_data_raw = data[data_index .. data_index + size];
                var signal_value: u32 = 0;

                switch (size) {
                    1 => {
                        signal_value = @as(u32, signal_data_raw[0]);
                    },
                    2 => {
                        signal_value = (@as(u32, signal_data_raw[0]) << 8) | @as(u32, signal_data_raw[1]);
                    },
                    3 => {
                        signal_value = (@as(u32, signal_data_raw[0]) << 8) | @as(u32, signal_data_raw[1]) | (@as(u32, signal_data_raw[2]) << 16);
                    },
                    4 => {
                        signal_value = (@as(u32, signal_data_raw[0]) << 8) | @as(u32, signal_data_raw[1]) | (@as(u32, signal_data_raw[2]) << 24) | (@as(u32, signal_data_raw[3]) << 16);
                    },
                    else => {
                        unreachable;
                    },
                }

                // stdout.print("original data {any}\n", .{signal_data_raw}) catch |err| {
                //     stderr.print("Error writing to stdout: {}\n", .{err}) catch {};
                // };

                const casted_value: i64 = @intCast(signal_value);
                const timestamp = std.time.milliTimestamp();

                // stdout.print("{d}, {d}\n", .{ casted_value - 8192, timestamp }) catch |err| {
                //     stderr.print("Error writing to stdout: {}\n", .{err}) catch {};
                // };

                processed_data_queue_mutex.lock();
                processed_data_queue.append(gpa.allocator(), ProcessedData{
                    .ppg_value = casted_value - 8192,
                    .timestamp_ms = @intCast(timestamp),
                }) catch |err| {
                    stderr.print("Error appending processed data: {}\n", .{err}) catch {};
                };
                processed_data_queue_mutex.unlock();

                data_index += size;
                current_slot_index = (current_slot_index + 1) % adpd_config.time_slots.len;
            }

            raw_data_queue.replaceRange(gpa.allocator(), 0, data_index, &[_]u8{}) catch |err| {
                stderr.print("Error removing processed data from queue: {}\n", .{err}) catch {};
            };

            stderr.flush() catch |err| {
                stderr.print("Error flushing stderr: {}\n", .{err}) catch {};
            };

            stdout.flush() catch |err| {
                stderr.print("Error flushing stdout: {}\n", .{err}) catch {};
            };
        }
    }
}

fn read_data_loop(adpd_sensor: *sensor.ADPD4101Sensor, interrupt_gpio: *gpio.GPIO) void {
    var sensor_active = true;
    while (!should_exit.load(.seq_cst)) {
        if (need_stop.load(.seq_cst)) {
            if (sensor_active) {
                sensor_active = false;
                adpd_sensor.disable(adpd_config.time_slots.len) catch |err| {
                    stderr.print("Error disabling ADPD4101 sensor: {}\n", .{err}) catch {};
                };
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        } else {
            if (!sensor_active) {
                sensor_active = true;
                adpd_sensor.enable(adpd_config.time_slots.len) catch |err| {
                    stderr.print("Error enabling ADPD4101 sensor: {}\n", .{err}) catch {};
                };
            }
        }
        interrupt_gpio.waitForInterrupt() catch |err| {
            stderr.print("Error waiting for GPIO interrupt: {}\n", .{err}) catch {};
            return;
        };
        const read_data = adpd_sensor.read_raw() catch |err| {
            stderr.print("Error reading data from ADPD4101 sensor: {}\n", .{err}) catch {};
            continue;
        };

        if (read_data.len == 0) {
            continue;
        }

        queue_mutex.lock();
        defer queue_mutex.unlock();
        // for (read_data) |byte| {
        //     data_queue.append(gpa.allocator(), byte) catch |err| {
        //         stderr.print("Error appending data to queue: {}\n", .{err}) catch {};
        //     };
        // }
        raw_data_queue.appendSlice(gpa.allocator(), read_data) catch |err| {
            stderr.print("Error appending read data to queue: {}\n", .{err}) catch {};
        };
    }
}

pub fn main() !void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handle_signal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(linux.SIG.INT, &act, null);

    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    raw_data_queue = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer raw_data_queue.deinit(allocator);

    processed_data_queue = try std.ArrayList(ProcessedData).initCapacity(allocator, 1024);
    defer processed_data_queue.deinit(allocator);

    var adpd4101_sensor = sensor.ADPD4101Sensor.init(
        adpd_config.i2c_device_path,
        adpd_config.device_address,
        adpd_config.oscillator,
        adpd_config.timeslot_freq_hz,
        &adpd_config.time_slots,
        adpd_config.use_ext_clock,
        adpd_config.fifo_threshold,
        adpd_config.gpio_id,
    ) catch |err| {
        // std.debug.print("Failed to initialize ADPD4101 sensor: {}\n", .{err});
        return err;
    };

    defer adpd4101_sensor.deinit();

    var interrupt_gpio = try gpio.GPIO.init(constant.interrupt_gpio_pin_id);
    defer interrupt_gpio.deinit() catch |err| {
        stderr.print("Failed to deinitialize GPIO: {}\n", .{err}) catch {};
    };

    const data_thread = try std.Thread.spawn(.{}, read_data_loop, .{ &adpd4101_sensor, &interrupt_gpio });
    defer data_thread.join();
    const process_thread = try std.Thread.spawn(.{}, process_data_queue, .{});
    defer process_thread.join();
    const bluetooth_thread = try std.Thread.spawn(.{}, send_data, .{});
    defer bluetooth_thread.join();

    while (!should_exit.load(.seq_cst)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

const ProcessedData = struct {
    ppg_value: i64,
    timestamp_ms: u64,
};
