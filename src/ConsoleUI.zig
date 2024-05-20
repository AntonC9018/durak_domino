const core = @import("core.zig");
const std = @import("std");
const UIObject = @import("UIObject.zig");
const EventQueue = @import("EventQueue.zig");

context: *core.GameLogicContext,
cout: @TypeOf(std.io.getStdOut().writer()),

const Self = @This();

pub fn setOptions(self: *Self, params: UIObject.SetOptionsParameters) !void
{
    switch (params.playOption)
    {
        .Defense =>
        {
            try printPlayersHand(self.context, self.context.state.defenderIndex(), self.cout);
            try self.cout.print("Player {} has to beat ", .{ self.context.state.defenderIndex() });
            const attack = self.context.state.play.attackCard.?;
            try attack.print(self.cout, self.context.config);
            try self.cout.print("\n", .{});

            const responsesIter = core.getPossibleDefenses(self.context) catch unreachable;
            var wrappedIter = wrapResponseIter(self.context, responsesIter);
            const selectedResponse = try collectOptionsFromIteratorAndSelectOne(
                self.context.allocator,
                &wrappedIter,
                self.cout,
                "Take all");

            const response: EventQueue.ResponseEvent = response:
            {
                switch (selectedResponse)
                {
                    .Empty =>
                    {
                        break :response .Take;
                    },
                    .Value => |v|
                    {
                        break :response .{
                            .Defense = v.response,
                        };
                    },
                }
            };

            try self.context.eventQueue.addEvent(.{
                .Response = response,
            });
        },
        .InitialAttack => 
        {
            const players = self.context.state.turnIndices;
            try printPlayersHand(self.context, players.attacker, self.cout);
            try self.cout.print("Player {} attacks player {}", .{ players.attacker, players.defender });

            const hand = core.getAttackerHand(self.context.state);
            const cardsInHandContext = CardInHandContext
            {
                .hand = hand,
                .config = self.context.config,
            };
            var wrappedIter = wrapCardIndexIterator(
                cardsInHandContext,
                CardsInHandIter.create(cardsInHandContext));
            const selectedAttackIndex = try collectOptionsFromIteratorAndSelectOne(
                self.context.allocator,
                &wrappedIter,
                self.cout,
                null);

            try self.context.eventQueue.addEvent(.{
                .Play = .{
                    .handCardIndex = selectedAttackIndex,
                },
            });
        },
        .ThrowAttack =>
        {
            var attackersIterator = core.PossibleAttackersIterator.create(self.context);
            try getAndRealizeAttackerThrowOption(self, &attackersIterator);
        },
        .None =>
        {
            unreachable;
        },
    }
}

pub fn passTurn(self: *Self, params: UIObject.PassTurnParameters) !void
{
    try printPlayersHand(self.context, params.players.attacker, self.cout);
    try self.cout.print("Player {} selects the card to attack with: \n", .{ self.context.state.attackerIndex() });
}

pub fn play(self: *Self, params: UIObject.PlayParameters) !void
{
    try self.cout.print("Player {} attacks with card {}\n", .{
        params.playerIndex,
        params.card,
    });
}

pub fn redraw(self: *Self, params: UIObject.RedrawParameters) !void
{
    for (params.draws.items) |draw|
    {
        try self.cout.print("Player {} draws {}\n", .{
            draw.playerIndex,
            draw.addedCards,
        });
    }
}

pub fn respond(self: *Self, params: UIObject.RespondParameters) !void
{
    try self.cout.print("Player {} responds with {}\n", .{
        params.playerIndex,
        params.response,
    });
}

pub fn throwIntoPlay(self: *Self, params: UIObject.ThrowIntoPlayParameters) !void
{
    try self.cout.print("Player {} throw {} into play\n", .{
        params.playerIndex,
        params.card,
    });
}

pub fn endPlay(self: *Self, params: UIObject.EndPlayParameters) !void
{
    try self.cout.print("Play ends\n", .{});
    _ = params;
}

pub fn gameOver(self: *Self, params: UIObject.GameOverParameters) !void
{
    try self.cout.print("Game over\n", .{});
    switch (params.result)
    {
        .Incomplete => unreachable,
        .Lose => |l| try self.cout.print("Player {} loses\n", .{ l }),
        .Tie => try self.cout.print("Tie\n", .{}),
    }
}

pub fn moveIntoDrawPile(self: *Self, params: UIObject.MoveIntoDrawPileParameters) !void
{
    try self.cout.print("{} have been moved to the draw pile", .{ params.cards });
}

pub fn resetPlay(self: *Self, params: UIObject.ResetPlayParameters) !void
{
    _ = params;
    try self.cout.print("Play has been reset", .{});
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

fn ItemType(Slice: type) type
{
    const info = @typeInfo(Slice);
    return info.Pointer.child;
}

fn iterateSlice(slice: anytype) SliceIter(ItemType(@TypeOf(slice)))
{
    return .{
        .ptr = slice.ptr,
        .rangeIter = .{
            .count = slice.len,
        },
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

pub fn wrapCardIndex(index: usize, context: CardInHandContext) CardInHand
{
    return .{
        .context = context,
        .cardIndex = index,
    };
}

const CardsInHandIter = struct
{
    rangeIter: RangeIter = undefined,
    context: CardInHandContext,

    pub fn create(context: CardInHandContext) CardsInHandIter
    {
        return .{
            .context = context,
            .rangeIter = .{
                .count = context.hand.cards.items.len,
            },
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
    response: core.Defense,
    context: *core.GameLogicContext,

    pub fn format(
        self: *const CardResponseWrapper,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        const r = self.response;
        const playerHand = core.getDefenderHand();

        const response: core.Card = playerHand.cards.items[r.handCardIndex];
        try response.print(writer, self.context.config);
        try writer.print(" -- ", .{});
        try response.printWithHighlightAt(writer, self.context.config, r.match.response);
    }
};

fn wrapResponse(a: core.Defense, b: *core.GameLogicContext) CardResponseWrapper
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

fn printPlayersHand(
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

fn printHand(
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

// This needs to be abstracted in some way, because this
// logic will be shared with the graphical module.
pub fn getAndRealizeAttackerThrowOption(self: *Self, iter: *core.AllPlayersThrowAttackIterator) !bool
{
    while (iter.next()) |playerIndex|
    {
        const cardHandContext = CardInHandContext
        {
            .config = self.context.config,
            .hand = &self.context.state.hands.items[playerIndex],
        };
        try printPlayersHand(self.context, playerIndex, self.cout);
        try self.cout.print("Player {} selects a card to throw in:\n", .{ playerIndex });

        var printableIter = wrapCardIndexIterator(cardHandContext, self.attackersIterator);
        const selectedOption = try collectOptionsFromIteratorAndSelectOne(
            self.context.allocator,
            &printableIter,
            self.cout,
            "Skip");

        try self.context.eventQueue.addEvent(.{
            .Throw = switch (selectedOption)
            {
                .Value => |v| break .{ .Throw = v },
                .Empty => continue,
            },
        });
        return true;
    }
    return false;
}
