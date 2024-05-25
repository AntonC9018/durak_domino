const core = @import("core.zig");
const std = @import("std");
const UIObject = @import("UIObject.zig");
const ConsoleUI = @import("ConsoleUI.zig");
const EventQueue = @import("EventQueue.zig");

pub fn main() !void
{
    var config = core.Config
    {
        .playerCount = 2,
        .handSize = 6,
        .maxValue = @enumFromInt(6),
        .faceCount = 2,
    };
    config.init();

    var gameState = core.GameState
    {
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var allocators = core.Allocators.create(allocator);
    var context = core.GameLogicContext
    {
        .allocators = &allocators,
        .state = &gameState,
        .randomState = std.rand.DefaultPrng.init(@bitCast(std.time.timestamp())),
        .config = &config,
        .ui = undefined,
        .eventQueue = EventQueue.create(allocator),
    };

    var ui: ConsoleUI = .{
        .context = &context,
        .cout = std.io.getStdOut().writer(),
    };
    context.ui = UIObject.create(&ui);

    try core.resetState(&context);

    while (true)
    {
        if (try core.gameLogicLoop(&context))
        {
            return;
        }
    }
}

test
{
    _ = core;
}
