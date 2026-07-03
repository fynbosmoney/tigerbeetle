const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const vsr = @import("../tb_client.zig").vsr;
const Header = vsr.Header;
const stdx = vsr.stdx;
const constants = vsr.constants;
const MessagePool = vsr.message_pool.MessagePool;
const Message = MessagePool.Message;
const Time = vsr.time.Time;

const MemoryBackend = @import("../../../testing/memory_forest.zig").Backend;
const StateMachineWithBackendType =
    @import("../../../state_machine.zig").StateMachineWithBackendType;

/// A `tb_client` client that bundles the real state machine with an in-memory, hashmap-backed
/// forest (see `src/testing/memory_forest.zig`), executing requests in-process with no networking,
/// consensus, or persistent storage. Exposed via `tb_client_init_testing`. Mirrors the decl
/// surface `ContextType` expects, exactly like `echo_client.zig`, but instead of echoing it runs
/// prepare/prefetch/commit against the bundled state machine.
pub fn TestingClientType(comptime MessageBus: type) type {
    const Storage = void;
    const StateMachineImpl = StateMachineWithBackendType(
        Storage,
        constants.state_machine_config,
        MemoryBackend,
    );
    const Grid = MemoryBackend.GridType(Storage);
    const VSRClient = vsr.ClientType(StateMachineImpl, MessageBus);

    return struct {
        const TestingClient = @This();
        const message_body_size_max = StateMachine.machine_constants.message_body_size_max;

        // Exposing the same types the real client does. Unlike the echo client, results are the
        // real state machine's results, so the state machine is exposed directly.
        pub const StateMachine = StateMachineImpl;
        pub const Request = VSRClient.Request;
        const Operation = StateMachine.Operation;

        id: u128,
        cluster: u128,
        release: vsr.Release = vsr.Release.minimum,
        request_number: u32 = 0,
        request_inflight: ?Request = null,
        message_pool: *MessagePool,
        time: Time,

        allocator: mem.Allocator,
        grid: *Grid,
        state_machine: StateMachine,
        op: u64 = 1,
        reply_buffer: []align(16) u8,
        busy: bool = false,

        pub fn init(
            allocator: mem.Allocator,
            time: Time,
            message_pool: *MessagePool,
            options: struct {
                id: u128,
                cluster: u128,
                replica_count: u8,
                message_bus_options: MessageBus.Options,
                eviction_callback: ?*const fn (
                    client: *TestingClient,
                    eviction: *const Message.Eviction,
                ) void = null,
            },
        ) !TestingClient {
            _ = options.replica_count;
            _ = options.message_bus_options;
            _ = options.eviction_callback;

            const grid = try allocator.create(Grid);
            errdefer allocator.destroy(grid);
            grid.* = .{};

            const reply_buffer = try allocator.alignedAlloc(u8, 16, message_body_size_max);
            errdefer allocator.free(reply_buffer);

            var client: TestingClient = .{
                .id = options.id,
                .cluster = options.cluster,
                .message_pool = message_pool,
                .time = time,
                .allocator = allocator,
                .grid = grid,
                .state_machine = undefined,
                .reply_buffer = reply_buffer,
            };

            try client.state_machine.init(allocator, time, client.grid, .{
                .batch_size_limit = message_body_size_max,
                .lsm_forest_compaction_block_count = 0,
                .lsm_forest_node_count = 0,
                .cache_entries_accounts = 0,
                .cache_entries_transfers = 0,
                .cache_entries_transfers_pending = 0,
                .log_trace = false,
            });
            return client;
        }

        pub fn deinit(self: *TestingClient, allocator: mem.Allocator) void {
            assert(self.allocator.ptr == allocator.ptr);
            if (self.request_inflight) |inflight| self.release_message(inflight.message.base());
            self.state_machine.deinit(allocator);
            allocator.free(self.reply_buffer);
            allocator.destroy(self.grid);
        }

        pub fn tick(self: *TestingClient) void {
            const inflight = self.request_inflight orelse return;
            self.request_inflight = null;

            switch (inflight.callback) {
                .register => |callback| {
                    self.release_message(inflight.message.base());
                    const result = vsr.RegisterResult{
                        .batch_size_limit = message_body_size_max,
                    };
                    callback(inflight.user_data, &result);
                },
                .request => |callback| {
                    const operation_vsr = inflight.message.header.operation;
                    const operation = StateMachine.operation_from_vsr(operation_vsr).?;
                    const input = inflight.message.body_used();
                    const timestamp = self.prepare(operation, input);
                    const pulse_needed = self.state_machine.pulse_needed(timestamp);

                    const reply_size = self.execute(operation, input, timestamp);
                    self.compact();
                    self.op += 1;
                    if (pulse_needed) self.pulse();

                    self.release_message(inflight.message.base());
                    callback(
                        inflight.user_data,
                        operation_vsr,
                        timestamp,
                        self.reply_buffer[0..reply_size],
                    );
                },
            }
        }

        // Assign the prepare timestamp the way the replica primary does: strictly increasing, and
        // at least wall-clock time.
        fn prepare(
            self: *TestingClient,
            operation: Operation,
            input: []align(16) const u8,
        ) u64 {
            self.state_machine.commit_timestamp = self.state_machine.prepare_timestamp;
            const realtime: u64 = @intCast(@max(self.time.realtime(), 0));
            self.state_machine.prepare_timestamp = @max(
                @max(
                    self.state_machine.prepare_timestamp,
                    self.state_machine.commit_timestamp,
                ) + 1,
                realtime,
            );
            self.state_machine.prepare(operation, input);
            return self.state_machine.prepare_timestamp;
        }

        fn execute(
            self: *TestingClient,
            operation: Operation,
            input: []align(16) const u8,
            timestamp: u64,
        ) usize {
            assert(!self.busy);
            self.busy = true;
            self.state_machine.prefetch_timestamp = timestamp;
            self.state_machine.prefetch(state_machine_callback, self.op, operation, input);
            while (self.busy) assert(self.grid.run_next_tick());

            const output: *align(16) [message_body_size_max]u8 = @ptrCast(self.reply_buffer.ptr);
            return self.state_machine.commit(
                self.id,
                self.op,
                timestamp,
                operation,
                input,
                output,
            );
        }

        fn compact(self: *TestingClient) void {
            assert(!self.busy);
            self.busy = true;
            self.state_machine.compact(state_machine_callback, self.op);
            while (self.busy) assert(self.grid.run_next_tick());
        }

        fn state_machine_callback(state_machine: *StateMachine) void {
            const self: *TestingClient = @alignCast(@fieldParentPtr(
                "state_machine",
                state_machine,
            ));
            assert(self.busy);
            self.busy = false;
        }

        fn pulse(self: *TestingClient) void {
            const operation = vsr.Operation.pulse.cast(StateMachine);
            const input: []align(16) const u8 = &.{};
            const timestamp = self.prepare(operation, input);
            _ = self.execute(operation, input, timestamp);
            self.compact();
            self.op += 1;
        }

        pub fn register(
            self: *TestingClient,
            callback: Request.RegisterCallback,
            user_data: u128,
        ) void {
            assert(self.request_inflight == null);
            assert(self.request_number == 0);

            const message = self.get_message().build(.request);
            message.header.* = .{
                .client = self.id,
                .request = self.request_number,
                .cluster = self.cluster,
                .command = .request,
                .operation = .register,
                .release = vsr.Release.minimum,
                .previous_request_latency = 0,
            };
            self.request_number += 1;
            self.request_inflight = .{
                .message = message,
                .user_data = user_data,
                .callback = .{ .register = callback },
            };
        }

        pub fn request(
            self: *TestingClient,
            callback: Request.Callback,
            user_data: u128,
            operation: StateMachine.Operation,
            events: []const u8,
        ) void {
            const event_size: usize = switch (operation) {
                inline else => |operation_comptime| @sizeOf(
                    StateMachine.EventType(operation_comptime),
                ),
            };
            assert(events.len <= message_body_size_max);
            assert(events.len % event_size == 0);

            const message = self.get_message().build(.request);
            errdefer self.release_message(message.base());

            message.header.* = .{
                .client = self.id,
                .request = 0, // Set by raw_request() below.
                .cluster = self.cluster,
                .command = .request,
                .release = vsr.Release.minimum,
                .operation = vsr.Operation.from(StateMachine, operation),
                .size = @intCast(@sizeOf(Header) + events.len),
                .previous_request_latency = 0,
            };

            stdx.copy_disjoint(.exact, u8, message.body_used(), events);
            self.raw_request(callback, user_data, message);
        }

        pub fn raw_request(
            self: *TestingClient,
            callback: Request.Callback,
            user_data: u128,
            message: *Message.Request,
        ) void {
            assert(message.header.client == self.id);
            assert(message.header.cluster == self.cluster);
            assert(message.header.release.value == self.release.value);
            assert(!message.header.operation.vsr_reserved());
            assert(message.header.size >= @sizeOf(Header));
            assert(message.header.size <= constants.message_size_max);

            message.header.request = self.request_number;
            self.request_number += 1;
            assert(self.request_inflight == null);
            self.request_inflight = .{
                .message = message,
                .user_data = user_data,
                .callback = .{ .request = callback },
            };
        }

        pub fn get_message(self: *TestingClient) *Message {
            return self.message_pool.get_message(null);
        }

        pub fn release_message(self: *TestingClient, message: *Message) void {
            self.message_pool.unref(message);
        }
    };
}
