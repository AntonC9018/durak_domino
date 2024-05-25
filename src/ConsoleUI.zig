const core = @import("core.zig");
const std = @import("std");
const UIObject = @import("UIObject.zig");
const EventQueue = @import("EventQueue.zig");
const utils = @import("utils.zig");

context: *core.GameLogicContext,
cout: @TypeOf(std.io.getStdOut().writer()),

const Self = @This();

pub fn setOptions(self: *Self, params: UIObject.SetOptionsParameters) !void
{
    switch (params.playOption)
    {
        .InitialAttack => 
        {
            const players = self.context.state.turnIndices;
            try printPlayersHand(self.context, players.attacker, self.cout);
            try self.cout.print("Player {} attacks player {}\n", .{ players.attacker, players.defender });

            const cardsInHand = core.getAttackerHand(self.context.state).cards.items;
            const cardsInHandContext = PrintableCardsSlice.fromCards(self.context, cardsInHand);
            var wrappedIter = wrapCardIndexIterator(
                cardsInHandContext,
                RangeIter.create(.{
                    .count = cardsInHand.len,
                }));
            const selectedAttack = try collectOptionsFromIteratorAndSelectOne(
                self.context.allocators.event.allocator(),
                &wrappedIter,
                self.cout,
                null);

            try self.context.eventQueue.addEvent(.{
                .Play = .{
                    .handCardIndex = selectedAttack.cardIndex,
                },
            });
        },
        .Defense =>
        {
            const playerIndex = self.context.state.defenderIndex();
            const attack = self.context.state.play.attackCard.?;
            try printPlayersHand(self.context, playerIndex, self.cout);
            try self.cout.print("Player {} has to beat {}\n", .{
                playerIndex,
                attack.asPrintable(self.context.config),
            });

            const responsesIter = core.getPossibleDefenses(self.context) catch unreachable;
            var wrappedIter = utils.wrapIterMethod(responsesIter, ResponsePrintContext
            {
                .context = self.context,
                .attack = attack,
            });
            const selectedResponse = try collectOptionsFromIteratorAndSelectOne(
                self.context.allocator(),
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
                            .Defense = v.defense,
                        };
                    },
                }
            };

            try self.context.eventQueue.addEvent(.{
                .Response = response,
            });
        },
        .ThrowAttack =>
        {
            var attackersIterator = core.PossibleAttackersIterator.create(self.context);
            _ = try getAndRealizeAttackerThrowOption(self, &attackersIterator);
        },
        .None =>
        {
            unreachable;
        },
    }
}

pub fn passTurn(self: *Self, params: UIObject.PassTurnParameters) !void
{
    _ = self;
    _ = params;
}

pub fn play(self: *Self, params: UIObject.PlayParameters) !void
{
    try self.cout.print("Player {} attacks with card {}\n", .{
        params.playerIndex,
        params.card.asPrintable(self.context.config),
    });
}

pub fn redraw(self: *Self, params: UIObject.RedrawParameters) !void
{
    for (params.draws.items) |draw|
    {
        try self.cout.print("Player {} draws {}\n", .{
            draw.playerIndex,
            PrintableCardsSlice.fromCards(self.context, draw.addedCards),
        });
    }
}

pub fn respond(self: *Self, params: UIObject.RespondParameters) !void
{
    try self.cout.print("Player {} responds with {}\n", .{
        params.playerIndex,
        params.card.asPrintable(self.context.config),
    });
}

pub fn throwIntoPlay(self: *Self, params: UIObject.ThrowIntoPlayParameters) !void
{
    try self.cout.print("Player {} throw {} into play\n", .{
        params.playerIndex,
        params.card.asPrintable(self.context.config),
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
    try self.cout.print("{} have been moved to the draw pile\n", .{ 
        PrintableCardsSlice.fromCards(self.context, params.cards),
    });
}

pub fn resetPlay(self: *Self, params: UIObject.ResetPlayParameters) !void
{
    _ = params;
    try self.cout.print("Play has been reset\n", .{});
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
    return utils.IterValueType(IterT);
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

        for (list.items) |item|
        {
            try cout.print("{}: {}\n", .{ optionIndex, item }); 
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
    endExclusive: usize,

    pub fn create(params: struct
        {
            start: usize = 0,
            count: usize,
        }) RangeIter
    {
        return .{
            .currentIndex = params.start,
            .endExclusive = params.start + params.count,
        };
    }

    pub fn next(self: *RangeIter) ?usize
    {
        if (self.currentIndex >= self.endExclusive)
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
            .endExclusive = slice.len,
        },
    };
}

const PrintableCardsSlice = struct
{
    cards: []const core.Card,
    config: *const core.Config,

    pub fn fromPlayerIndex(context: *core.GameLogicContext, playerIndex: u8) PrintableCardsSlice
    {
        return .{
            .cards = context.state.hands.items[playerIndex].cards.items,
            .config = context.config,
        };
    }

    pub fn fromCards(context: *core.GameLogicContext, cards: []const core.Card) PrintableCardsSlice
    {
        return .{
            .cards = cards,
            .config = context.config,
        };
    }

    pub fn format(
        self: PrintableCardsSlice,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        for (0 .., self.cards) |i, c|
        {
            if (i != 0)
            {
                try writer.print(" | ", .{});
            }
            try c.asPrintable(self.config).print(writer);
        }
    }
};

const CardInHand = struct
{
    context: PrintableCardsSlice,
    cardIndex: usize,

    pub fn card(self: *const CardInHand) core.Card
    {
        return self.context.cards[self.cardIndex];
    }

    pub fn format(
        self: *const CardInHand,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        try self.card().asPrintable(self.context.config).print(writer);
    }
};

pub fn wrapCardIndex(index: usize, context: PrintableCardsSlice) CardInHand
{
    return .{
        .context = context,
        .cardIndex = index,
    };
}

const CardsInHandIter = struct
{
    rangeIter: RangeIter = undefined,
    context: PrintableCardsSlice,

    pub fn create(context: PrintableCardsSlice) CardsInHandIter
    {
        return .{
            .context = context,
            .rangeIter = .{
                .count = context.cards.len,
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

const CardResponseWrapper = struct
{
    defense: core.Defense,
    context: *core.GameLogicContext,
    attack: core.Card,

    pub fn format(
        self: CardResponseWrapper,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        const r = self.defense;
        const playerHand = core.getDefenderHand(self.context.state);

        const response: core.Card = playerHand.cards.items[r.handCardIndex];
        const attack_ = self.attack;
        const config = self.context.config;
        try writer.print("{} > {}", .{
            response.asPrintableWithHighlight(config, r.match.response),
            attack_.asPrintableWithHighlight(config, r.match.attack),
        });
    }
};

const ResponsePrintContext = struct
{
    context: *core.GameLogicContext,
    attack: core.Card,

    pub fn wrap(self: ResponsePrintContext, defense: core.Defense) CardResponseWrapper
    {
        return .{
            .context = self.context,
            .attack = self.attack,
            .defense = defense,
        };
    }
};

fn wrapCardIndexIterator(context: PrintableCardsSlice, iter: anytype)
    utils.WrapIterFunc(@TypeOf(iter), @TypeOf(context), wrapCardIndex)
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
    const printableHand = PrintableCardsSlice.fromPlayerIndex(context, playerIndex);
    try cout.print("Player {}'s hand: {any}\n", .{ playerIndex, printableHand });
}

// This needs to be abstracted in some way, because this
// logic will be shared with the graphical module.
pub fn getAndRealizeAttackerThrowOption(self: *Self, iter: *core.PossibleAttackersIterator) !bool
{
    while (iter.next()) |playerIndex|
    {
        try printPlayersHand(self.context, playerIndex, self.cout);
        try self.cout.print("Player {} selects a card to throw in (allowed side value = {}):\n", .{
            playerIndex,
            self.context.state.play.nextAllowedValue.?.asPrintable(self.context.config),
        });

        const cardHandContext = PrintableCardsSlice.fromPlayerIndex(self.context, playerIndex);
        const cardIter = core.ThrowAttackCardIndexIterator.fromPlayerIndex(self.context, playerIndex);
        var printableIter = wrapCardIndexIterator(cardHandContext, cardIter);
        const selectedOption = try collectOptionsFromIteratorAndSelectOne(
            self.context.allocator(),
            &printableIter,
            self.cout,
            "Skip");

        switch (selectedOption)
        {
            .Empty => {},
            .Value => |v| 
            {
                try self.context.eventQueue.addEvent(.{
                    .Throw = .{
                        .Throw = .{
                            .handCardIndex = v.cardIndex,
                            .attackerIndex = playerIndex,
                        },
                    },
                });
                return true;
            },
        }
    }
    try self.context.eventQueue.addEvent(.{
        .Throw = .Skip,
    });
    return false;
}
