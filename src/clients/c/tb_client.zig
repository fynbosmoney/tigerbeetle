const std = @import("std");

pub const vsr = @import("../../vsr.zig");
pub const exports = @import("tb_client_exports.zig");

const constants = @import("../../constants.zig");
const IO = @import("../../io.zig").IO;
const Storage = @import("../../storage.zig").StorageType(IO);
const MessageBus = @import("../../message_bus.zig").MessageBusClient;
const StateMachineType = @import("../../state_machine.zig").StateMachineType;
const StateMachine = StateMachineType(Storage, constants.state_machine_config);

pub const InitError = @import("tb_client/context.zig").InitError;
pub const InitParameters = @import("tb_client/context.zig").InitParameters;
pub const ClientInterface = @import("tb_client/context.zig").ClientInterface;
pub const CompletionCallback = @import("tb_client/context.zig").CompletionCallback;
pub const Packet = @import("tb_client/packet.zig").Packet.Extern;
pub const PacketStatus = @import("tb_client/packet.zig").Packet.Status;
pub const Operation = StateMachine.Operation;

const ContextType = @import("tb_client/context.zig").ContextType;
const DefaultContext = blk: {
    const ClientType = @import("../../vsr/client.zig").ClientType;
    const Client = ClientType(StateMachine, MessageBus);
    break :blk ContextType(Client);
};

const EchoContext = blk: {
    const EchoClientType = @import("tb_client/echo_client.zig").EchoClientType;
    const EchoClient = EchoClientType(StateMachine, MessageBus);
    break :blk ContextType(EchoClient);
};

const TestingContext = blk: {
    const TestingClientType = @import("tb_client/testing_client.zig").TestingClientType;
    const TestingClient = TestingClientType(MessageBus);
    break :blk ContextType(TestingClient);
};

pub const init = DefaultContext.init;
pub const init_echo = EchoContext.init;
pub const init_testing = TestingContext.init;

test {
    std.testing.refAllDecls(DefaultContext);
    std.testing.refAllDecls(TestingContext);
}
