const dbus = @import("dbus");
const std = @import("std");

// only support bluez
pub const Bluetooth = struct {
    dbus_stream: std.net.Stream,
    writer_buf: [1000]u8,
    reader_buf: [1000]u8,
    socket_writer: std.net.Stream.Writer,
    socket_reader: std.net.Stream.Reader,
    source_state: dbus.SourceState,
    source: dbus.Source,
    next_serial: u32 = 1,

    pub fn init() !Bluetooth {
        const session_addr_str = dbus.getSessionBusAddressString();
        const addr = try dbus.Address.fromString(session_addr_str.str);

        var bt = Bluetooth{
            .writer_buf = undefined,
            .reader_buf = undefined,
            .dbus_stream = try dbus.connect(addr),
            .socket_reader = undefined,
            .socket_writer = undefined,
            .source_state = .auth,
            .source = undefined,
        };

        bt.socket_writer = dbus.socketWriter(bt.dbus_stream, &bt.writer_buf);
        bt.socket_reader = dbus.socketReader(bt.dbus_stream, &bt.reader_buf);
        bt.source = dbus.Source{
            .reader = bt.socket_reader.interface(),
            .state = &bt.source_state,
        };

        // start the authentication process
        try dbus.flushAuth(&bt.socket_writer.interface);
        try bt.source.readAuth();
        // if we reach here, we are authenticated
        const serial = bt.getNextSerial();
        try bt.socket_writer.interface.writeAll("BEGIN\r\n");
        try dbus.writeMethodCall(
            &bt.socket_writer.interface,
            "",
            .{
                .serial = serial,
                .destination = .initStatic("org.freedesktop.DBus"),
                .path = .initStatic("/org/freedesktop/DBus"),
                .interface = .initStatic("org.freedesktop.DBus"),
                .member = .initStatic("Hello"),
            },
            .{},
        );
        try bt.socket_writer.interface.flush();

        var name_buf: [dbus.max_name:0]u8 = undefined;

        const name = blk_name: {
            while (true) {
                const msg_start = try bt.source.readMsgStart();

                switch (msg_start.type) {
                    .method_return => {
                        break;
                    },
                    .method_call => {
                        return error.UnexpectedDbusMethodCall;
                    },
                    .error_reply => {
                        try bt.source.discardRemaining();
                        return error.DbusErrorReply;
                    },
                    .signal => {
                        // ignore signals for now
                        std.debug.print("Ignoring signal\n", .{});

                        try bt.source.discardRemaining();
                    },
                }
            }

            const headers = try bt.source.readHeadersMethodReturn(&.{});

            try headers.expectReplySerial(serial);
            try bt.source.expectSignature("s");
            const string_size: u32 = try bt.source.readBody(.string_size, {});
            const name_len: u8 = dbus.castNameLen(string_size) orelse {
                return error.InvalidBusNameLength;
            };

            try bt.source.dataReadSliceAll(name_buf[0..name_len]);
            try bt.source.dataReadNullTerm();
            try bt.source.bodyEnd();
            break :blk_name name_buf[0..name_len];
        };

        std.log.info("Connected to bus with name: {s}", .{name});
        return bt;
    }

    pub fn introspect(self: *Bluetooth) !void {
        const serial = self.getNextSerial();
        try self.socket_writer.interface.writeAll("BEGIN\r\n");
        try dbus.writeMethodCall(
            &self.socket_writer.interface,
            "",
            .{
                .serial = serial,
                .destination = .initStatic(BLUEZ_SERVICE_NAME),
                .path = .initStatic(BLUEZ_ROOT_PATH),
                .interface = .initStatic("org.freedesktop.DBus.Introspectable"),
                .member = .initStatic("Introspect"),
            },
            .{},
        );

        try self.socket_writer.interface.flush();

        while (true) {
            const msg_start = try self.source.readMsgStart();

            switch (msg_start.type) {
                .method_return => {
                    break;
                },
                .method_call => {
                    return error.UnexpectedDbusMethodCall;
                },
                .error_reply => {
                    try self.source.discardRemaining();
                    return error.DbusErrorReply;
                },
                .signal => {
                    // ignore signals for now
                    std.debug.print("Ignoring signal\n", .{});

                    try self.source.discardRemaining();
                },
            }
        }

        std.debug.print("Introspection Result:\n", .{});

        const headers = try self.source.readHeadersMethodReturn(&.{});

        try headers.expectReplySerial(serial);
        try self.source.expectSignature("s");
        const string_size = try self.source.readBody(.string_size, {});

        const string_limit = self.source.bodyOffset() + string_size + 1;
        while (self.source.bodyOffset() + 1 < string_limit) {
            const remaining = self.source.dataRemaining();

            if (remaining == 1) break;
            const take_len = @min(remaining - 1, self.socket_reader.interface().buffer.len);
            std.debug.print("{s}", .{try self.source.dataTake(take_len)});
        }

        try self.source.dataReadNullTerm();
        try self.source.bodyEnd();
    }

    fn getNextSerial(self: *Bluetooth) u32 {
        const serial = self.next_serial;
        self.next_serial += 1;
        return serial;
    }
};

const BLUEZ_SERVICE_NAME = "org.bluez";
const BLUEZ_ROOT_PATH = "/org/bluez";
