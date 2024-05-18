const core = @import("core.zig");
const std = @import("std");
const UIObject = @import("UIObject.zig");
const ConsoleUI = @import("ConsoleUI.zig");

pub fn endPlayAndTurn(context: *core.GameLogicContext) !void
{
    try core.endPlay(context);
    try core.redraw(context);
    try core.moveTurnToNextPlayer(context);
}

const PlayCardCallback = struct
{
    context: *core.GameLogicContext,

    const Self = @This();

    pub fn execute(self: *Self, value: core.PossibleResponse) std.mem.Allocator.Error
    {
        context.controllerEvents.append();
    }
};
    
pub fn gameLogicLoop(context: *core.GameLogicContext) !bool
{
    const endState = core.getCompletionStatus(context.state);
    if (endState != .Incomplete)
    {
        context.ui.gameOver(.{
            .result = endState,
        });
        return true;
    }

    if (context.controllerEvents.items.len == 0)
    {
        return false;
    }

    for (context.controllerEvents.items) |ev|
    {
        switch (ev)
        {
            .PossibleResponse => |response|
            {
                try core.startPlayCard(context, response.match.attack);
            },
        }
    }

    switch (core.gameStateHelper(context))
    {
        .Play =>
        {

            var iter = playerVisualCardsIterator(
                context,
                context.state.attackerIndex());
            const selectedOption = try collectOptionsFromIteratorAndSelectOne(
                // can use arena here easily.
                context.allocator,
                &iter,
                cout,
                null);
            try core.startPlayCard(context, selectedOption.cardIndex);
        },
        .Respond =>
        {
            {
                try printPlayersHand(context, context.state.defenderIndex(), cout);
                try cout.print("Player {} has to beat ", .{ context.state.defenderIndex() });
                const attack = context.state.play.attackCard.?;
                try attack.print(cout, context.config);
                try cout.print("\n", .{});
            }

            const responsesIter = try core.getPossibleResponses(context);
            var wrappedIter = wrapResponseIter(context, responsesIter);
            const selectedResponse = try collectOptionsFromIteratorAndSelectOne(
                context.allocator,
                &wrappedIter,
                cout,
                "Take all");

            switch (selectedResponse)
            {
                .Empty => try core.takePlayIntoHand(context),
                .Value => |v| try core.core.respond(context, v.response),
            }
        },
        .ThrowIntoPlayOrEnd =>
        {
            if (!core.isDefenderAbleToRespond(context.state))
            {
                endPlayAndTurn(context)
                    catch |err|
                    {
                        switch (err)
                        {
                            error.GameOver =>
                            {
                                const good = try showGameOver(context, cout);
                                std.debug.assert(good);
                                return true;
                            },
                            else => return err,
                        }
                    };
                return false;
            }

            if (uiContext.attackersIterator == null)
            {
                uiContext.attackersIterator = .{
                    .context = context,
                };
                uiContext.attackersIterator.?.init();
            }

            const didSomeOption = try getAndRealizeAttackerThrowOption(uiContext, context, cout);
            uiContext.attackersIterator = null;

            if (!didSomeOption)
            {
                try endPlayAndTurn(context);
            }
        },
    }
    return false;
}

pub fn main() !void
{
    var config = core.Config
    {
        .playerCount = 2,
        .handSize = 6,
        .maxValue = 6,
        .faceCount = 2,
    };
    config.init();

    var gameState = core.GameState
    {
    };

    var context = core.GameLogicContext
    {
        .allocator = std.heap.page_allocator,
        .state = &gameState,
        .randomState = std.rand.DefaultPrng.init(@bitCast(std.time.timestamp())),
        .config = &config,
    };
    try core.resetState(&context);

    var uiContext = ConsoleUI
    {
        .attackersIterator = null,
    };

    while (true)
    {
        if (try gameLogicLoop(&context, &uiContext))
        {
            return;
        }
    }
}
