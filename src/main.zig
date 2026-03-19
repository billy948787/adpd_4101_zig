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

var raw_adpd_queue_mutex = std.Thread.Mutex{};
var raw_imu_queue_mutex = std.Thread.Mutex{};
var processed_data_queue_mutex = std.Thread.Mutex{};

var should_exit = std.atomic.Value(bool).init(false);
var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
var raw_adpd_data_queue: std.ArrayList(u8) = undefined;
var raw_imu_data_queue: std.ArrayList(imu_cpp.ImuData) = undefined;
var processed_data_queue: std.ArrayList(ProcessedData(adpd_config.time_slots.len)) = undefined;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

var need_stop = std.atomic.Value(bool).init(false);

var serial_number = std.atomic.Value(u32).init(0);

fn handle_signal(signum: c_int) callconv(.c) void {
    _ = signum;
    should_exit.store(true, .seq_cst);
}

fn send_data() void {
    var bt_output = bluetooth_output.BluetoothClassicOutput.init() catch |err| {
        stderr.print("Error initializing Bluetooth output: {}\n", .{err}) catch {};
        return;
    };
    var fbs_buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&fbs_buffer);
    const writer = fbs.writer();
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
                fbs.reset();
                writer.print("{d},{s},{d},{d}", .{
                    serial_number.load(.seq_cst),
                    item.sensor_type,
                    item.sensor_timestamp,
                    item.host_monotonic_timestamp,
                }) catch |err| {
                    stderr.print("Error formatting header: {}\n", .{err}) catch {};
                    continue;
                };

                for (item.ppg_value) |ppg| {
                    writer.print(",{d}", .{ppg}) catch |err| {
                        stderr.print("Error formatting PPG value: {}\n", .{err}) catch {};
                        continue;
                    };
                }

                writer.print(",{d},{d},{d},{d},{d},{d}\n", .{
                    item.ax,
                    item.ay,
                    item.az,
                    item.gx,
                    item.gy,
                    item.gz,
                }) catch |err| {
                    stderr.print("Error formatting IMU data: {}\n", .{err}) catch {};
                    continue;
                };

                bt_output.write(fbs.getWritten()) catch |err| {
                    stderr.print("Error writing data to Bluetooth: {}\n", .{err}) catch {};
                    bt_output.closeClient() catch |close_err| {
                        stderr.print("Error closing Bluetooth client socket: {}\n", .{close_err}) catch {};
                    };
                    break;
                };

                _ = serial_number.fetchAdd(1, .seq_cst);
            }
            processed_data_queue.clearRetainingCapacity();
        }
        processed_data_queue_mutex.unlock();
    }
}

fn process_imu_queue() void {
    var is_enabled = false;
    while (!should_exit.load(.seq_cst)) {
        if (need_stop.load(.seq_cst)) {
            if (is_enabled) {
                is_enabled = false;
                std.debug.print("Sensor disabled, pausing IMU data processing.\n", .{});
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        } else {
            if (!is_enabled) {
                is_enabled = true;
                std.debug.print("Sensor enabled, resuming IMU data processing.\n", .{});
            }
        }

        raw_imu_queue_mutex.lock();
        var local_queue = std.ArrayList(ProcessedData).initCapacity(gpa.allocator(), raw_imu_data_queue.items.len) catch |err| {
            stderr.print("Error initializing local IMU data queue: {}\n", .{err}) catch {};
            raw_imu_queue_mutex.unlock();
            return;
        };
        if (raw_imu_data_queue.items.len > 0) {
            const data = raw_imu_data_queue.items;
            for (data) |item| {
                // Process IMU data here, e.g., print or store it
                if (item.status != 0) continue;
                local_queue.append(gpa.allocator(), ProcessedData{
                    .sensor_type = "IMU",
                    .sensor_timestamp = @intFromFloat(item.timestamp_s),
                    .host_monotonic_timestamp = monotonicNs(),
                    .ppg_value = 0,
                    .ax = item.ax,
                    .ay = item.ay,
                    .az = item.az,
                    .gx = item.gx,
                    .gy = item.gy,
                    .gz = item.gz,
                }) catch |err| {
                    stderr.print("Error processing IMU data: {}\n", .{err}) catch {};
                };
            }
            raw_imu_data_queue.clearRetainingCapacity();
        }
        raw_imu_queue_mutex.unlock();

        processed_data_queue_mutex.lock();

        processed_data_queue.appendSlice(gpa.allocator(), local_queue.items) catch |err| {
            stderr.print("Error appending processed IMU data to main queue: {}\n", .{err}) catch {};
        };

        processed_data_queue_mutex.unlock();
    }
}

fn process_adpd_queue() void {
    var timeslot_signal_size_arr: [adpd_config.time_slots.len]usize = undefined;

    inline for (adpd_config.time_slots, 0..) |slot, i| {
        timeslot_signal_size_arr[i] = @intCast(slot.data_format.sig_size);
    }

    const period_us: i64 = @divTrunc(1_000_000, @as(i64, adpd_config.timeslot_freq_hz));

    var current_slot_index: usize = 0;

    var first_sample_time_us: i64 = 0;
    var sample_counter: i64 = 0;
    var time_initialized = false;

    var is_enable = false;
    var prev_sum_status: i32 = -1;
    while (!should_exit.load(.seq_cst)) {
        if (need_stop.load(.seq_cst)) {
            if (is_enable) {
                is_enable = false;
                time_initialized = false;
                std.debug.print("Sensor disabled, pausing ADPD data processing.\n", .{});
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        } else {
            if (!is_enable) {
                is_enable = true;
                std.debug.print("Sensor enabled, resuming ADPD data processing.\n", .{});
            }
        }
        raw_adpd_queue_mutex.lock();
        defer raw_adpd_queue_mutex.unlock();

        var processed_data: ProcessedData(adpd_config.time_slots.len) = undefined;

        if (raw_adpd_data_queue.items.len > 0) {
            const data = raw_adpd_data_queue.items;
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

                if (!time_initialized) {
                    first_sample_time_us = std.time.microTimestamp();
                    time_initialized = true;
                }

                // stdout.print("original data {any}\n", .{signal_data_raw}) catch |err| {
                //     stderr.print("Error writing to stdout: {}\n", .{err}) catch {};
                // };

                const casted_value: i64 = @intCast(signal_value);
                const timestamp = first_sample_time_us + sample_counter * period_us;

                stdout.print("{d}, {d}\n", .{ casted_value - 8192, timestamp }) catch |err| {
                    stderr.print("Error writing to stdout: {}\n", .{err}) catch {};
                };

                processed_data.ppg_value[current_slot_index] = casted_value - 8192;

                data_index += size;

                if (adpd_config.fifo_status_sum_enable and current_slot_index == adpd_config.time_slots.len - 1 and data_index < data.len) {
                    var status_sum = data[data_index];

                    data_index += 1;

                    status_sum &= 0b00001111;

                    if (prev_sum_status != -1) {
                        const expected: u8 = @intCast((@as(u8, @intCast(prev_sum_status)) +% 1) & 0x0F);
                        if (status_sum != expected) {
                            stderr.print("Warning: FIFO status sum gap! expected {d}, got {d}\n", .{ expected, status_sum }) catch {};
                        }
                    }

                    prev_sum_status = status_sum;
                }
                if (current_slot_index == adpd_config.time_slots.len - 1) {
                    processed_data_queue_mutex.lock();
                    processed_data.sensor_type = "ADPD";
                    processed_data.sensor_timestamp = timestamp;
                    processed_data.host_monotonic_timestamp = monotonicNs();
                    processed_data_queue.append(gpa.allocator(), processed_data) catch |err| {
                        stderr.print("Error appending processed ADPD data to main queue: {}\n", .{err}) catch {};
                    };
                    processed_data_queue_mutex.unlock();

                    sample_counter += 1;
                }
                current_slot_index = (current_slot_index + 1) % adpd_config.time_slots.len;
            }

            raw_adpd_data_queue.replaceRange(gpa.allocator(), 0, data_index, &[_]u8{}) catch |err| {
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

fn read_imu_data_loop() void {
    var sensor_active = true;
    const result = imu_cpp.imu_enable();

    if (result != 0) {
        stderr.print("Failed to enable IMU: error code {}\n", .{result}) catch {};
        return;
    }
    var fifo_buf: [imu_cpp.IMU_FIFO_MAX_SAMPLES]imu_cpp.ImuData = undefined;
    while (!should_exit.load(.seq_cst)) {
        if (need_stop.load(.seq_cst)) {
            if (sensor_active) {
                sensor_active = false;
                imu_cpp.imu_disable();
                std.debug.print("Sensor disabled, pausing IMU data reading.\n", .{});
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        } else {
            if (!sensor_active) {
                sensor_active = true;
                _ = imu_cpp.imu_enable();
                std.debug.print("Sensor enabled, resuming IMU data reading.\n", .{});
            }
        }

        var count: c_int = 0;
        _ = imu_cpp.imu_read_fifo(&fifo_buf, imu_cpp.IMU_FIFO_MAX_SAMPLES, &count);

        if (count > 0) {
            raw_imu_queue_mutex.lock();
            for (fifo_buf[0..@intCast(count)]) |item| {
                raw_imu_data_queue.append(gpa.allocator(), item) catch |err| {
                    stderr.print("Error appending IMU data to queue: {}\n", .{err}) catch {};
                };
            }
            raw_imu_queue_mutex.unlock();
        }
    }
}

fn read_adpd_data_loop(adpd_sensor: *sensor.ADPD4101Sensor, interrupt_gpio: *gpio.GPIO) void {
    var sensor_active = true;
    adpd_sensor.enable(adpd_config.time_slots.len) catch |err| {
        stderr.print("Error enabling ADPD4101 sensor: {}\n", .{err}) catch {};
    };
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

        raw_adpd_queue_mutex.lock();
        defer raw_adpd_queue_mutex.unlock();
        // for (read_data) |byte| {
        //     data_queue.append(gpa.allocator(), byte) catch |err| {
        //         stderr.print("Error appending data to queue: {}\n", .{err}) catch {};
        //     };
        // }
        raw_adpd_data_queue.appendSlice(gpa.allocator(), read_data) catch |err| {
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

    raw_adpd_data_queue = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer raw_adpd_data_queue.deinit(allocator);

    raw_imu_data_queue = try std.ArrayList(imu_cpp.ImuData).initCapacity(allocator, 1024);
    defer raw_imu_data_queue.deinit(allocator);

    processed_data_queue = try std.ArrayList(ProcessedData(adpd_config.time_slots.len)).initCapacity(allocator, 1024);
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
        adpd_config.fifo_status_sum_enable,
    ) catch |err| {
        // std.debug.print("Failed to initialize ADPD4101 sensor: {}\n", .{err});
        return err;
    };

    defer adpd4101_sensor.deinit();

    var interrupt_gpio = try gpio.GPIO.init(constant.interrupt_gpio_pin_id);
    defer interrupt_gpio.deinit() catch |err| {
        stderr.print("Failed to deinitialize GPIO: {}\n", .{err}) catch {};
    };

    // const result = imu_cpp.imu_init();

    // if (result != 0) {
    //     stderr.print("Failed to initialize IMU: error code {}\n", .{result}) catch {};
    //     return;
    // }
    // defer imu_cpp.imu_deinit();

    const adpd_thread = try std.Thread.spawn(.{}, read_adpd_data_loop, .{ &adpd4101_sensor, &interrupt_gpio });
    defer adpd_thread.join();
    const process_adpd_thread = try std.Thread.spawn(.{}, process_adpd_queue, .{});
    defer process_adpd_thread.join();
    // const process_imu_thread = try std.Thread.spawn(.{}, process_imu_queue, .{});
    // defer process_imu_thread.join();
    const bluetooth_thread = try std.Thread.spawn(.{}, send_data, .{});
    defer bluetooth_thread.join();
    // const imu_thread = try std.Thread.spawn(.{}, read_imu_data_loop, .{});
    // defer imu_thread.join();

    while (!should_exit.load(.seq_cst)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

pub fn ProcessedData(comptime num_timeslots: usize) type {
    return struct {
        sensor_type: []const u8,
        sensor_timestamp: i64,
        host_monotonic_timestamp: u64,
        ppg_value: [num_timeslots]i64,

        ax: i16,
        ay: i16,
        az: i16,
        gx: i16,
        gy: i16,
        gz: i16,
    };
}

fn monotonicNs() u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}
