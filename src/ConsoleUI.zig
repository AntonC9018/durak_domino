const core = @import("core.zig");
const std = @import("std.zig");
const UIObject = @import("UIObject.zig");

context: *core.GameLogicContext,
attackersIterator: ?core.PossibleAttackersIterator,
cout: @TypeOf(std.cout.writer()) = std.cout.writer(),

const Self = @This();

pub fn setResponses(self: Self, params: UIObject.SetResponsesParameters) bool
{
}

pub fn passTurn(self: Self, params: UIObject.PassTurnParameters) bool
{
    printPlayersHand(self.context, params.players.attacker, self.cout)
        catch return false;
    self.cout.print("Player {} selects the card to attack with: \n", .{ self.context.state.attackerIndex() })
        catch return false;
    return true;
}

pub fn play(self: Self, params: UIObject.PlayParameters) bool
{
}

pub fn redraw(self: Self, params: UIObject.RedrawParameters) bool
{
}

pub fn respond(self: Self, params: UIObject.RespondParameters) bool
{
}

pub fn throwIntoPlay(self: Self, params: UIObject.ThrowIntoPlayParameters) bool
{
}

pub fn endPlay(self: Self, params: UIObject.EndPlayParameters) bool
{
}

pub fn gameOver(self: Self, params: UIObject.GameOverParameters) bool
{
}

pub fn moveIntoDrawPile(self: Self, params: UIObject.MoveIntoDrawPileParameters) bool
{
}

pub fn resetPlay(self: Self, params: UIObject.ResetPlayParameters) bool
{
}

fn showGameOver(context: *core.GameLogicContext, cout: anytype) !bool
{
    const endState = core.getCompletionStatus(context.state);
    switch (endState)
    {
        .Incomplete =>
        {
            return false;
        },
        .Lose => |i|
        {
            try cout.print("Player {} loses.\n", .{ i });
        },
        .Tie =>
        {
            try cout.print("Tie.\n", .{});
        },
    }
    return true;
}

fn IterValueType(IterT: type) type
{
    const T = @TypeOf(b: {
        var t = @as(IterT, undefined);
        break :b t.next().?;
    });
    return T;
}

fn IterOutputType(IterMaybePointerT: type) type
{
    const IterT = IterT: 
    {
        const info = @typeInfo(IterMaybePointerT);
        switch (info)
        {
            .Pointer => |p| break :IterT p.child,
            .Struct => break :IterT IterMaybePointerT,
            else => unreachable,
        }
    };
    return IterValueType(IterT);
}

fn CollectOptionsResult(IterT: type, comptime allowEmptyOption: bool) type
{
    const T = IterOutputType(IterT);
    if (allowEmptyOption)
    {
        return union(enum)
        {
            Empty: enum
            {
                forced,
                manual,
            },
            Value: T,
        };
    }

    return T;
}

fn collectOptionsFromIteratorAndSelectOne(
    allocator: std.mem.Allocator,
    iter: anytype,
    cout: anytype,
    comptime emptyLabel: ?[]const u8) 
    
    !CollectOptionsResult(@TypeOf(iter), emptyLabel != null)
{
    const allowEmptyOption = emptyLabel != null;
    std.debug.assert(@typeInfo(@TypeOf(iter)) == .Pointer);

    const OptionType = IterOutputType(@TypeOf(iter));
    var list = std.mem.zeroInit(std.ArrayList(OptionType), .{
        .allocator = allocator,
    });
    defer list.deinit();

    while (iter.next()) |n|
    {
        try list.append(n);
    }

    if (list.items.len == 0)
    {
        if (allowEmptyOption)
        {
            return .{ .Empty = .forced };
        }
        unreachable;
    }

    const optionCount = optionCount:
    {
        var optionIndex: usize = 0;
        if (emptyLabel) |label|
        {
            try cout.print("{}: " ++ label ++ "\n", .{ optionIndex });
            optionIndex += 1;
        }

        for (list.items) |n|
        {
            try cout.print("{}: {}\n", .{ optionIndex, n }); 
            optionIndex += 1;
        }

        break :optionCount optionIndex;
    };

    while (true)
    {
        const reader = std.io.getStdIn().reader();
        const arr = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 9999)
            orelse
            {
                try cout.print("Nothing given as input?\n", .{});
                continue;
            };
        defer allocator.free(arr);

        const inputOption = std.fmt.parseInt(usize, arr, 10)
            catch |err|
            {
                switch (err)
                {
                    error.Overflow =>
                    {
                        try cout.print("The number {s} is too large.\n", .{ arr });
                        continue;
                    },
                    error.InvalidCharacter =>
                    {
                        try cout.print("Invalid character in number {s}.\n", .{ arr });
                        continue;
                    },
                }
            };

        if (inputOption >= optionCount)
        {
            try cout.print("The input {} is too large.\n", .{ inputOption });
            continue;
        }

        const iteratorOption = iteratorOption:
        {
            if (allowEmptyOption and inputOption == 0)
            {
                return .{ .Empty = .manual };
            }
            if (allowEmptyOption)
            {
                break :iteratorOption inputOption - 1;
            }
            break :iteratorOption inputOption;
        };

        const result = list.items[iteratorOption];
        if (allowEmptyOption)
        {
            return .{ .Value = result };
        }
        return result;
    }
}

const RangeIter = struct
{
    currentIndex: usize = 0,
    count: usize,

    pub fn next(self: *RangeIter) ?usize
    {
        if (self.currentIndex >= self.count)
        {
            return null;
        }

        defer self.currentIndex += 1;

        return self.currentIndex;
    }
};

fn SliceIter(T: type) type
{
    return struct
    {
        const Self1 = @This();

        ptr: [*]T,
        rangeIter: RangeIter,

        pub fn next(self: *Self1) ?*T
        {
            if (self.rangeIter.next()) |n|
            {
                return &self.ptr[n];
            }

            return null;
        }
    };
}

const CardInHandContext = struct
{
    hand: *const core.Hand,
    config: *const core.Config,
};

const CardInHand = struct
{
    context: CardInHandContext,
    cardIndex: usize,

    pub fn card(self: *const CardInHand) core.Card
    {
        return self.context.hand.cards.items[self.cardIndex];
    }

    pub fn format(
        self: *const CardInHand,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        try self.card().print(writer, self.context.config);
    }
};

pub fn wrapCardIndex(value: usize, context: CardInHandContext) CardInHand
{
    return .{
        .context = context,
        .cardIndex = value,
    };
}

const CardsInHandIter = struct
{
    rangeIter: RangeIter = undefined,
    context: CardInHandContext,

    pub fn init(self: *CardsInHandIter) void
    {
        self.rangeIter = .{
            .count = self.context.hand.cards.items.len,
        };
    }

    pub fn next(self: *CardsInHandIter) ?CardInHand
    {
        if (self.rangeIter.next()) |n|
        {
            return .{
                .cardIndex = n,
                .context = self.context,
            };
        }

        return null;
    }
};

pub fn playerVisualCardsIterator(context: *core.GameLogicContext, playerIndex: u8) CardsInHandIter
{
    var t = CardsInHandIter
    {
        .context = .{
            .hand = &context.state.hands.items[playerIndex],
            .config = context.config,
        },
    };
    t.init();
    return t;
}

fn WrapIter(
    TIter: type,
    TContext: type,
    // fn(@TypeOf(TIter), TContext) -> Wrapped(@TypeOf(TIter))
    wrapFunc: anytype) type
{
    const IterOutputT = IterValueType(TIter);
    const WrappedIterOutputType = @TypeOf(
        wrapFunc(
            @as(IterOutputT, undefined),
            @as(TContext, undefined)));

    return struct
    {
        const Self1 = @This();

        iter: TIter,
        context: TContext,

        pub fn next(self: *Self1) ?WrappedIterOutputType
        {
            if (self.iter.next()) |n|
            {
                return wrapFunc(n, self.context);
            }
            return null;
        }
    };
}

const CardResponseWrapper = struct
{
    response: core.PossibleResponse,
    context: *core.GameLogicContext,

    pub fn format(
        self: *const CardResponseWrapper,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        const r = self.response;
        const playerHand = &self.context.state.hands.items[self.context.state.defenderIndex()];

        const response: core.Card = playerHand.cards.items[r.handCardIndex];
        try response.print(writer, self.context.config);
        try writer.print(" -- ", .{});
        try response.printWithHighlightAt(writer, self.context.config, r.match.response);
    }
};

fn wrapResponse(a: core.PossibleResponse, b: *core.GameLogicContext) CardResponseWrapper
{
    return .{
        .response = a,
        .context = b,
    };
}

fn wrapResponseIter(context: *core.GameLogicContext, iter: core.PossibleResponsesIterator) 
    WrapIter(core.PossibleResponsesIterator, *core.GameLogicContext, wrapResponse)
{
    return .{
        .context = context,
        .iter = iter,
    };
}

fn wrapCardIndexIterator(context: CardInHandContext, iter: anytype)
    WrapIter(@TypeOf(iter), @TypeOf(context), wrapCardIndex)
{
    return .{
        .context = context,
        .iter = iter,
    };
}

pub fn printPlayersHand(
    context: *core.GameLogicContext,
    playerIndex: u8,
    cout: anytype) !void
{
    try cout.print("Player {}'s hand: ", .{ playerIndex });
    try printHand(.{
        .hand = &context.state.hands.items[playerIndex],
        .config = context.config,
    }, cout);
    try cout.print("\n", .{});
}

pub fn printHand(
    context: CardInHandContext,
    cout: anytype) !void
{
    for (0 .., context.hand.cards.items) |i, c|
    {
        if (i != 0)
        {
            try cout.print(" | ", .{});
        }
        try c.print(cout, context.config);
    }
}

// TODO: This will need a controller abstraction.
pub fn getAndRealizeAttackerThrowOption(uiContext: *Self, context: *core.GameLogicContext, cout: anytype) !bool
{
    while (uiContext.attackersIterator.?.next()) |playerIndex|
    {
        const cardHandContext = CardInHandContext
        {
            .config = context.config,
            .hand = &context.state.hands.items[playerIndex],
        };
        try printPlayersHand(context, playerIndex, cout);
        try cout.print("Player {} selects a card to throw in:\n", .{ playerIndex });

        const iter = core.getCardsAllowedForThrow(context, playerIndex);
        var printableIter = wrapCardIndexIterator(cardHandContext, iter);
        const selectedOption = try collectOptionsFromIteratorAndSelectOne(
            context.allocator,
            &printableIter,
            cout,
            "Skip");

        switch (selectedOption)
        {
            .Empty => continue,
            .Value => |v| 
            {
                try core.throwIntoPlay(context, playerIndex, v.cardIndex);
                return true;
            }
        }
    }
    return false;
}
