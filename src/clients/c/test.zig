const std = @import("std");
const assert = std.debug.assert;

const testing = std.testing;

const tb_client = @import("tb_client.zig");
const stdx = tb_client.vsr.stdx;
const constants = @import("../../constants.zig");
const tb = tb_client.vsr.tigerbeetle;

const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

fn RequestContextType(comptime request_size_max: comptime_int) type {
    return struct {
        const RequestContext = @This();

        completion: *Completion,
        packet: tb_client.Packet,
        sent_data: [request_size_max]u8 = undefined,
        sent_data_size: u32,
        reply: ?struct {
            tb_context: usize,
            tb_packet: *tb_client.Packet,
            timestamp: u64,
            result: ?[request_size_max]u8,
            result_len: u32,
        } = null,

        pub fn on_complete(
            tb_context: usize,
            tb_packet: *tb_client.Packet,
            timestamp: u64,
            result_ptr: ?[*]const u8,
            result_len: u32,
        ) callconv(.c) void {
            var self: *RequestContext = @ptrCast(@alignCast(tb_packet.*.user_data.?));
            defer self.completion.complete();

            self.reply = .{
                .tb_context = tb_context,
                .tb_packet = tb_packet,
                .timestamp = timestamp,
                .result = if (result_ptr != null and result_len > 0) blk: {
                    // Copy the message's body to the context buffer:
                    assert(result_len <= request_size_max);
                    var writable: [request_size_max]u8 = undefined;
                    const readable: [*]const u8 = @ptrCast(result_ptr.?);
                    stdx.copy_disjoint(.inexact, u8, &writable, readable[0..result_len]);
                    break :blk writable;
                } else null,
                .result_len = result_len,
            };
        }
    };
}

// Notifies the main thread when all pending requests are completed.
const Completion = struct {
    pending: usize,
    mutex: Mutex = .{},
    cond: Condition = .{},

    pub fn complete(self: *Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        assert(self.pending > 0);
        self.pending -= 1;
        self.cond.signal();
    }

    pub fn wait_pending(self: *Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.pending > 0)
            self.cond.wait(&self.mutex);
    }
};

// Consistency of U128 across Zig and the language clients.
// It must be kept in sync with all platforms.
test "u128 consistency test" {
    const decimal: u128 = 214850178493633095719753766415838275046;
    const binary = [16]u8{
        0xe6, 0xe5, 0xe4, 0xe3, 0xe2, 0xe1,
        0xd2, 0xd1, 0xc2, 0xc1, 0xb2, 0xb1,
        0xa4, 0xa3, 0xa2, 0xa1,
    };
    const pair: extern struct { lower: u64, upper: u64 } = .{
        .lower = 15119395263638463974,
        .upper = 11647051514084770242,
    };

    try testing.expectEqual(decimal, @as(u128, @bitCast(binary)));
    try testing.expectEqual(binary, @as([16]u8, @bitCast(decimal)));

    try testing.expectEqual(decimal, @as(u128, @bitCast(pair)));
    try testing.expectEqual(pair, @as(@TypeOf(pair), @bitCast(decimal)));
}

// When initialized with `init_echo`, the tb_client uses a test context that echoes
// the data back without creating an actual client or connecting to a cluster.
//
// This same test should be implemented by all the target programming languages, asserting that:
// 1. the tb_client api was initialized correctly.
// 2. the application can submit messages and receive replies through the completion callback.
// 3. the data marshaling is correct, and exactly the same data sent was received back.
test "tb_client echo" {
    // Using the create_accounts operation for this test.
    const RequestContext = RequestContextType(constants.message_body_size_max);

    // Test multiple operations to prevent all requests from ending up in the same batch.
    const operations = [_]tb_client.Operation{
        tb_client.Operation.create_accounts,
        tb_client.Operation.create_transfers,
        tb_client.Operation.lookup_accounts,
        tb_client.Operation.lookup_transfers,
        tb_client.Operation.get_account_transfers,
        tb_client.Operation.get_account_balances,
        tb_client.Operation.query_accounts,
        tb_client.Operation.query_transfers,
    };

    // Initializing an echo client for testing purposes.
    // We ensure that the retry mechanism is being tested
    // by allowing more simultaneous packets than "client_request_queue_max".
    var client: tb_client.ClientInterface = undefined;
    const cluster_id: u128 = 0;
    const address = "3000";
    const concurrency_max: u32 = constants.client_request_queue_max * operations.len;
    const tb_context: usize = 42;
    try tb_client.init_echo(
        testing.allocator,
        &client,
        cluster_id,
        address,
        tb_context,
        RequestContext.on_complete,
    );

    defer client.deinit() catch unreachable;
    var prng = stdx.PRNG.from_seed(tb_context);

    const requests: []RequestContext = try testing.allocator.alloc(
        RequestContext,
        concurrency_max,
    );
    defer testing.allocator.free(requests);

    // Repeating the same test multiple times to stress the
    // cycle of message exhaustion followed by completions.
    const repetitions_max = 100;
    var repetition: u32 = 0;
    var operation_current: ?tb_client.Operation = null;
    while (repetition < repetitions_max) : (repetition += 1) {
        var completion = Completion{ .pending = concurrency_max };

        const operation: tb_client.Operation = operation: {
            if (operation_current == null or
                // Sometimes repeat the same operation for testing multi-batch.
                prng.boolean())
            {
                operation_current = operations[prng.index(operations)];
            }
            break :operation operation_current.?;
        };

        const event_size: u32, const event_request_max: u32 = switch (operation) {
            // All multi-batched operations require a minimum trailer size of one element:
            .create_accounts => .{
                @sizeOf(tb.Account),
                @divExact(constants.message_body_size_max, @sizeOf(tb.Account)) - 1,
            },
            .create_transfers => .{
                @sizeOf(tb.Transfer),
                @divExact(constants.message_body_size_max, @sizeOf(tb.Transfer)) - 1,
            },
            .lookup_accounts => .{
                @sizeOf(u128),
                @divExact(constants.message_body_size_max, @sizeOf(tb.Account)) - 1,
            },
            .lookup_transfers => .{
                @sizeOf(u128),
                @divExact(constants.message_body_size_max, @sizeOf(tb.Transfer)) - 1,
            },
            .get_account_transfers, .get_account_balances => .{
                @sizeOf(tb.AccountFilter),
                1,
            },
            .query_accounts, .query_transfers => .{
                @sizeOf(tb.QueryFilter),
                1,
            },
            else => unreachable,
        };

        // Submitting some random data to be echoed back:
        for (requests) |*request| {
            request.* = .{
                .packet = undefined,
                .completion = &completion,
                .sent_data_size = prng.range_inclusive(
                    u32,
                    1,
                    event_request_max,
                ) * event_size,
            };
            prng.fill(request.sent_data[0..request.sent_data_size]);

            const packet = &request.packet;
            packet.operation = @intFromEnum(operation);
            packet.user_data = request;
            packet.data = &request.sent_data;
            packet.data_size = request.sent_data_size;
            packet.user_tag = 0;
            packet.status = .ok;

            try client.submit(packet);
        }

        // Waiting until the c_client thread has processed all submitted requests:
        completion.wait_pending();

        // Checking if the received echo matches the data we sent:
        for (requests) |*request| {
            try testing.expect(request.reply != null);
            try testing.expectEqual(tb_context, request.reply.?.tb_context);
            try testing.expectEqual(tb_client.PacketStatus.ok, request.packet.status);
            try testing.expectEqual(
                @intFromPtr(&request.packet),
                @intFromPtr(request.reply.?.tb_packet),
            );
            try testing.expect(request.reply.?.result != null);
            try testing.expectEqual(request.sent_data_size, request.reply.?.result_len);

            const sent_data = request.sent_data[0..request.sent_data_size];
            const reply = request.reply.?.result.?[0..request.reply.?.result_len];
            try testing.expectEqualSlices(u8, sent_data, reply);
        }
    }
}

test "tb_client testing state machine" {
    const RequestContext = RequestContextType(constants.message_body_size_max);
    const submit = struct {
        fn run(
            client: *tb_client.ClientInterface,
            operation: tb_client.Operation,
            data: []const u8,
        ) !RequestContext {
            var completion = Completion{ .pending = 1 };
            var request = RequestContext{
                .packet = undefined,
                .completion = &completion,
                .sent_data_size = @intCast(data.len),
            };
            stdx.copy_disjoint(.inexact, u8, request.sent_data[0..data.len], data);
            request.packet = .{
                .operation = @intFromEnum(operation),
                .user_data = &request,
                .data = &request.sent_data,
                .data_size = request.sent_data_size,
                .user_tag = 0,
                .status = .ok,
            };
            try client.submit(&request.packet);
            completion.wait_pending();
            try testing.expectEqual(tb_client.PacketStatus.ok, request.packet.status);
            try testing.expect(request.reply != null);
            return request;
        }
    }.run;

    var client: tb_client.ClientInterface = undefined;
    try tb_client.init_testing(
        testing.allocator,
        &client,
        0,
        "3000",
        42,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    const accounts = [_]tb.Account{
        std.mem.zeroInit(tb.Account, .{ .id = 1, .ledger = 1, .code = 1 }),
        std.mem.zeroInit(tb.Account, .{ .id = 2, .ledger = 1, .code = 1 }),
    };
    const create_accounts = try submit(&client, .create_accounts, std.mem.sliceAsBytes(&accounts));
    // No results means both accounts were created successfully.
    try testing.expectEqual(@as(u32, 0), create_accounts.reply.?.result_len);

    const transfers = [_]tb.Transfer{std.mem.zeroInit(tb.Transfer, .{
        .id = 1,
        .debit_account_id = 1,
        .credit_account_id = 2,
        .amount = 10,
        .ledger = 1,
        .code = 1,
    })};
    const create_transfers = try submit(
        &client,
        .create_transfers,
        std.mem.sliceAsBytes(&transfers),
    );
    try testing.expectEqual(@as(u32, 0), create_transfers.reply.?.result_len);

    const ids = [_]u128{ 1, 2 };
    const lookup = try submit(&client, .lookup_accounts, std.mem.sliceAsBytes(&ids));
    try testing.expectEqual(@as(u32, 2 * @sizeOf(tb.Account)), lookup.reply.?.result_len);
    const result_bytes = lookup.reply.?.result.?[0..lookup.reply.?.result_len];
    const account_1 = std.mem.bytesToValue(tb.Account, result_bytes[0..@sizeOf(tb.Account)]);
    const account_2 = std.mem.bytesToValue(tb.Account, result_bytes[@sizeOf(tb.Account)..]);
    try testing.expectEqual(@as(u128, 10), account_1.debits_posted);
    try testing.expectEqual(@as(u128, 10), account_2.credits_posted);

    // Reversed scan: account 2 is only ever the credit side, so the debit-side scan is empty.
    // This exercises `merge_union` when a merged input has fewer than two elements — the case
    // where a direction inferred from the data (rather than the query) would be wrong.
    const more_transfers = [_]tb.Transfer{
        std.mem.zeroInit(tb.Transfer, .{
            .id = 4,
            .debit_account_id = 1,
            .credit_account_id = 2,
            .amount = 1,
            .ledger = 1,
            .code = 1,
        }),
        std.mem.zeroInit(tb.Transfer, .{
            .id = 5,
            .debit_account_id = 1,
            .credit_account_id = 2,
            .amount = 1,
            .ledger = 1,
            .code = 1,
        }),
    };
    _ = try submit(&client, .create_transfers, std.mem.sliceAsBytes(&more_transfers));

    const reversed_filter = std.mem.zeroInit(tb.AccountFilter, .{
        .account_id = 2,
        .limit = 10,
        .flags = tb.AccountFilterFlags{ .debits = true, .credits = true, .reversed = true },
    });
    const reversed = try submit(
        &client,
        .get_account_transfers,
        std.mem.asBytes(&reversed_filter),
    );
    const reversed_transfers = std.mem.bytesAsSlice(
        tb.Transfer,
        reversed.reply.?.result.?[0..reversed.reply.?.result_len],
    );
    // Newest-first: transfers 1, 4, 5 credited account 2, so a reversed scan yields 5, 4, 1.
    try testing.expectEqual(@as(usize, 3), reversed_transfers.len);
    try testing.expectEqual(@as(u128, 5), reversed_transfers[0].id);
    try testing.expectEqual(@as(u128, 4), reversed_transfers[1].id);
    try testing.expectEqual(@as(u128, 1), reversed_transfers[2].id);
    try testing.expect(reversed_transfers[0].timestamp > reversed_transfers[1].timestamp);
    try testing.expect(reversed_transfers[1].timestamp > reversed_transfers[2].timestamp);

    // Two-phase transfer: pending then post. Exercises the transfers_pending groove and the
    // `expires_at` index put on create and remove on post.
    const pending = [_]tb.Transfer{std.mem.zeroInit(tb.Transfer, .{
        .id = 6,
        .debit_account_id = 1,
        .credit_account_id = 2,
        .amount = 7,
        .ledger = 1,
        .code = 1,
        .timeout = 1000,
        .flags = tb.TransferFlags{ .pending = true },
    })};
    _ = try submit(&client, .create_transfers, std.mem.sliceAsBytes(&pending));

    const after_pending = try submit(&client, .lookup_accounts, std.mem.sliceAsBytes(&[_]u128{1}));
    const account_pending = std.mem.bytesToValue(
        tb.Account,
        after_pending.reply.?.result.?[0..@sizeOf(tb.Account)],
    );
    try testing.expectEqual(@as(u128, 7), account_pending.debits_pending);
    const debits_posted_before = account_pending.debits_posted;

    const post = [_]tb.Transfer{std.mem.zeroInit(tb.Transfer, .{
        .id = 7,
        .pending_id = 6,
        .amount = 7,
        .ledger = 1,
        .code = 1,
        .flags = tb.TransferFlags{ .post_pending_transfer = true },
    })};
    const post_result = try submit(&client, .create_transfers, std.mem.sliceAsBytes(&post));
    try testing.expectEqual(@as(u32, 0), post_result.reply.?.result_len);

    const after_post = try submit(&client, .lookup_accounts, std.mem.sliceAsBytes(&[_]u128{1}));
    const account_post = std.mem.bytesToValue(
        tb.Account,
        after_post.reply.?.result.?[0..@sizeOf(tb.Account)],
    );
    try testing.expectEqual(@as(u128, 0), account_post.debits_pending);
    try testing.expectEqual(debits_posted_before + 7, account_post.debits_posted);
}

// Asserts the validation rules associated with the `init*` functions.
test "tb_client init" {
    const assert_status = struct {
        pub fn action(
            addresses: []const u8,
            expected: tb_client.InitError!void,
        ) !void {
            var client_out: tb_client.ClientInterface = undefined;
            const cluster_id: u128 = 0;
            const tb_context: usize = 0;
            const result = tb_client.init_echo(
                testing.allocator,
                &client_out,
                cluster_id,
                addresses,
                tb_context,
                RequestContextType(0).on_complete,
            );
            defer if (!std.meta.isError(result)) client_out.deinit() catch unreachable;
            try testing.expectEqual(expected, result);
        }
    }.action;

    // Valid addresses should return TB_STATUS_SUCCESS:
    try assert_status("3000", {});
    try assert_status("127.0.0.1", {});
    try assert_status("127.0.0.1:3000", {});
    try assert_status("3000,3001,3002", {});
    try assert_status("127.0.0.1,127.0.0.2,172.0.0.3", {});
    try assert_status("127.0.0.1:3000,127.0.0.1:3002,127.0.0.1:3003", {});

    // Invalid or empty address should return "TB_STATUS_ADDRESS_INVALID":
    try assert_status("invalid", error.AddressInvalid);
    try assert_status("", error.AddressInvalid);

    // More addresses than "replicas_max" should return "TB_STATUS_ADDRESS_LIMIT_EXCEEDED":
    try assert_status(
        ("3000," ** constants.replicas_max) ++ "3001",
        error.AddressLimitExceeded,
    );

    // All other status are not testable.
}

// Asserts the validation rules associated with the client status.
test "tb_client client status" {
    const RequestContext = RequestContextType(0);
    var client: tb_client.ClientInterface = undefined;
    const cluster_id: u128 = 0;
    const addresses = "3000";
    const tb_context: usize = 0;
    try tb_client.init_echo(
        testing.allocator,
        &client,
        cluster_id,
        addresses,
        tb_context,
        RequestContext.on_complete,
    );
    errdefer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 1 };
    var request = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    const packet = &request.packet;
    packet.operation = @intFromEnum(tb_client.Operation.create_accounts);
    packet.user_data = &request;
    packet.data = null;
    packet.data_size = 0;
    packet.user_tag = 0;
    packet.status = .ok;

    // Sanity test to verify that the client is working.
    try client.submit(packet);
    completion.wait_pending();

    // Deinit the client.
    try client.deinit();

    // Cannot submit after deinit.
    try testing.expectError(error.ClientInvalid, client.submit(packet));

    // Multiple deinit calls are safe.
    try testing.expectError(error.ClientInvalid, client.deinit());
}

// Asserts the validation rules associated with the "PacketStatus" enum.
test "tb_client PacketStatus" {
    const RequestContext = RequestContextType(constants.message_body_size_max);

    var client_out: tb_client.ClientInterface = undefined;
    const cluster_id: u128 = 0;
    const addresses = "3000";
    const tb_context: usize = 42;
    try tb_client.init_echo(
        testing.allocator,
        &client_out,
        cluster_id,
        addresses,
        tb_context,
        RequestContext.on_complete,
    );
    defer client_out.deinit() catch unreachable;

    const assert_result = struct {
        // Asserts if the packet's status matches the expected status
        // for a given operation and request_size.
        pub fn action(
            client: *tb_client.ClientInterface,
            operation: u8,
            request_size: u32,
            packet_status_expected: tb_client.PacketStatus,
        ) !void {
            var completion = Completion{ .pending = 1 };
            var request = RequestContext{
                .packet = undefined,
                .completion = &completion,
                .sent_data_size = request_size,
            };

            const packet = &request.packet;
            packet.operation = operation;
            packet.user_data = &request;
            packet.data = &request.sent_data;
            packet.data_size = request_size;
            packet.user_tag = 0;
            packet.status = .ok;

            try client.submit(packet);

            completion.wait_pending();

            try testing.expect(request.reply != null);
            try testing.expectEqual(tb_context, request.reply.?.tb_context);
            try testing.expectEqual(
                @intFromPtr(&request.packet),
                @intFromPtr(request.reply.?.tb_packet),
            );
            try testing.expectEqual(packet_status_expected, request.packet.status);
        }
    }.action;

    // Messages larger than constants.message_body_size_max should return "too_much_data":
    try assert_result(
        &client_out,
        @intFromEnum(tb_client.Operation.create_transfers),
        constants.message_body_size_max + @sizeOf(tb_client.exports.tb_transfer_t),
        .too_much_data,
    );

    // All reserved and unknown operations should return "invalid_operation":
    try assert_result(
        &client_out,
        0,
        @sizeOf(u128),
        .invalid_operation,
    );
    try assert_result(
        &client_out,
        1,
        @sizeOf(u128),
        .invalid_operation,
    );
    try assert_result(
        &client_out,
        99,
        @sizeOf(u128),
        .invalid_operation,
    );
    try assert_result(
        &client_out,
        254,
        @sizeOf(u128),
        .invalid_operation,
    );

    // Messages not a multiple of the event size
    // should return "invalid_data_size":
    try assert_result(
        &client_out,
        @intFromEnum(tb_client.Operation.create_transfers),
        @sizeOf(tb_client.exports.tb_transfer_t) - 1,
        .invalid_data_size,
    );
    try assert_result(
        &client_out,
        @intFromEnum(tb_client.Operation.lookup_transfers),
        @sizeOf(u128) + 1,
        .invalid_data_size,
    );
    try assert_result(
        &client_out,
        @intFromEnum(tb_client.Operation.lookup_accounts),
        @sizeOf(u128) * 2.5,
        .invalid_data_size,
    );

    // Messages with zero length or multiple of the event size are valid.
    try assert_result(
        &client_out,
        @intFromEnum(tb_client.Operation.create_accounts),
        0,
        .ok,
    );
    try assert_result(
        &client_out,
        @intFromEnum(tb_client.Operation.create_accounts),
        @sizeOf(tb_client.exports.tb_account_t),
        .ok,
    );
    try assert_result(
        &client_out,
        @intFromEnum(tb_client.Operation.create_accounts),
        @sizeOf(tb_client.exports.tb_account_t) * 2,
        .ok,
    );
}
