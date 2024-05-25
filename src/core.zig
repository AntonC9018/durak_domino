const std = @import("std");
const UIObject = @import("UIObject.zig");
const EventQueue = @import("EventQueue.zig");

pub const maxSideCount = 8;

pub const Card = struct
{
    values: [maxSideCount]CardSide,

    pub fn getValuesSlice(card: anytype, conf: *const Config)
        switch (@TypeOf(card))
        {
            *Card => []CardSide,
            *const Card => []const CardSide,
            else => unreachable
        }
    {
        return card.values[0 .. conf.faceCount];
    }

    pub fn asPrintable(self: Card, conf: *const Config) PrintableCard
    {
        return .{
            .config = conf,
            .card = self,
        };
    }

    pub fn asPrintableWithHighlight(self: Card, conf: *const Config, highlightIndex: u8) PrintableCard
    {
        return .{
            .config = conf,
            .card = self,
            .highlightIndex = highlightIndex,
        };
    }
};

pub const PrintableCard = struct
{
    config: *const Config,
    card: Card,
    highlightIndex: ?u8 = null,

    pub fn format(
        self: PrintableCard,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        try print(self, writer);
    }

    pub fn print(self: PrintableCard, writer: anytype) !void
    {
        const values = self.card.getValuesSlice(self.config);
        for (0 .., values) |i, v|
        {
            if (i != 0)
            {
                try writer.print("-", .{});
            }

            const shouldHighlight = if (self.highlightIndex) |h| i == h else false;
            if (shouldHighlight)
            {
                try writer.print("*", .{});
            }

            try writer.print("{}", .{ v.asPrintable(self.config) });

            if (shouldHighlight)
            {
                try writer.print("*", .{});
            }
        }
    }
};

pub fn createCard(values: anytype) Card
{
    comptime std.debug.assert(values.len <= maxSideCount);
    var card = std.mem.zeroes(Card);
    inline for (card.values[0 .. values.len], &values) |*to, from|
    {
        to.* = @enumFromInt(from);
    }
    return card;
}

pub const CardSide = enum(u8)
{ 
    _,

    pub fn value(a: CardSide) u8
    {
        return @intFromEnum(a);
    }

    pub fn isWildcard(a: CardSide, config: *const Config) bool
    {
        std.debug.assert(a.value() <= config.maxValue.value());
        return a.value() == config.maxValue.value();
    }

    pub fn asPrintable(a: CardSide, config: *const Config) struct
    {
        side: CardSide,
        config_: *const Config,

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype) !void
        {
            if (self.side.isWildcard(self.config_))
            {
                try writer.print(" ", .{});
            }
            else
            {
                try writer.print("{d}", .{ @intFromEnum(self.side) });
            }
        }
    }
    {
        return .{
            .side = a,
            .config_ = config,
        };
    }
};

pub const Hand = struct
{
    cards: std.ArrayListUnmanaged(Card) = .{},
};

pub const Config = struct
{
    maxValue: CardSide,
    faceCount: u8,
    handSize: u8,
    deckSize: u32 = undefined,
    playerCount: u8,

    pub fn numValuesForFace(self: *Config) u8
    {
        return @intFromEnum(self.maxValue) + 1;
    }

    pub fn init(self: *Config) void
    {
        // Triangle numbers for more than 2 are harder.
        std.debug.assert(self.faceCount == 2);

        const numSelectionForEachFace = self.numValuesForFace();
        const numCombinations = numSelectionForEachFace * (numSelectionForEachFace + 1) / 2;
        // Could just calculate it after we've inserted all the elements.
        // It doesn't have to be through a formula.
        self.deckSize = numCombinations;
    }
};

pub const CurrentPlayers = struct
{
    attacker: u8,
    defender: u8,
};

pub const GameState = struct
{
    hands: std.ArrayListUnmanaged(Hand) = .{},
    drawPile: std.ArrayListUnmanaged(Card) = .{},
    discardPile: std.ArrayListUnmanaged(Card) = .{},
    turnIndices: CurrentPlayers = undefined,
    play: PlayState = undefined,

    pub fn attackerIndex(self: *const GameState) u8
    {
        return self.turnIndices.attacker;
    }

    pub fn defenderIndex(self: *const GameState) u8
    {
        return self.turnIndices.defender;
    }
};

pub const Allocators = struct
{
    general: std.mem.Allocator,
    event: std.heap.ArenaAllocator,
    play: std.heap.ArenaAllocator,

    pub fn create(allocator: std.mem.Allocator) Allocators
    {
        return .{
            .general = allocator,
            .event = std.heap.ArenaAllocator.init(allocator),
            .play = std.heap.ArenaAllocator.init(allocator),
        };
    }
};

pub const GameLogicContext = struct
{
    config: *Config,
    state: *GameState,
    allocators: *Allocators,
    randomState: std.rand.Xoshiro256,
    ui: UIObject,
    eventQueue: EventQueue,

    pub fn allocator(self: GameLogicContext) std.mem.Allocator
    {
        return self.allocators.general;
    }
};

pub const CardPair = struct
{
    attack: Card,
    response: Card,
};

pub const PlayState = struct
{
    attackCard: ?Card = null,
    completePairs: std.ArrayListUnmanaged(CardPair) = .{},
    nextAllowedValue: ?CardSide = null,

    pub fn started(self: *const PlayState) bool
    {
        return self.attackCard != null or self.completePairs.items.len != 0;
    }

    pub fn reset(self: *PlayState) void
    {
        self.attackCard = null;
        self.completePairs = .{};
        self.nextAllowedValue = null;
    }
};

pub const CompletionStatus = union(enum)
{
    Lose: u8,
    Incomplete: void,
    Tie: void,
};

pub fn getCompletionStatus(game: *const GameState) CompletionStatus
{
    if (game.drawPile.items.len != 0)
    {
        return .{ .Incomplete = {} };
    }

    const firstNonEmptyIndex: usize = firstNonEmptyIndex:
    {
        for (0 .., game.hands.items) |i, *hand|
        {
            if (hand.cards.items.len != 0)
            {
                break :firstNonEmptyIndex i;
            }
        }
        break :firstNonEmptyIndex null;
    } orelse return .{ .Tie = {} };

    for (game.hands.items[firstNonEmptyIndex ..]) |*hand|
    {
        if (hand.cards.items.len != 0)
        {
            return .{ .Incomplete = {} };
        }
    }
    return .{ .Lose = @intCast(firstNonEmptyIndex) };
}

pub fn getCardValues(card: *Card, conf: Config) []u8
{
    return card.values[0 .. conf.faceCount];
}

pub const ValueIndexMatchPair = struct
{
    response: u8,
    attack: u8,
};

pub const Defense = struct
{
    handCardIndex: usize,
    match: ValueIndexMatchPair,
};

pub const InitialAttack = struct
{
    handCardIndex: usize,
};

pub const ThrowAttack = struct
{
    attackerIndex: usize,
    handCardIndex: usize,
};

fn allDefensesBeatAllAttacks(p: struct
    {
        defense: Card,
        attack: Card,
        match: ValueIndexMatchPair,
        config: *const Config,
    }) bool
{
    std.debug.assert(p.config.faceCount == 2);

    const otherAttackIndex = (p.match.attack +% 1) % 2;
    const otherAttack = p.attack.values[otherAttackIndex];

    const otherDefenseIndex = (p.match.response +% 1) % 2;
    const otherDefense = p.defense.values[otherDefenseIndex];

    if (otherDefense.value() > otherAttack.value())
    {
        return true;
    }
    return false;
}

pub const MatchesIteratorState = struct
{
    attackIndex: u8 = 0,
    defenseIndex: u8 = 0,
    matchingWildcards: bool = false,
};

pub const MatchesIterator = struct
{
    state: MatchesIteratorState = .{},
    attackCard: Card,
    defenseCard: Card,
    config: *const Config,

    pub fn advance(self: *MatchesIterator) void
    {
        std.debug.assert(!self.isDone());

        const s = &self.state;

        s.attackIndex += 1;
        if (s.attackIndex < self.config.faceCount)
        {
            return;
        }
        s.attackIndex = 0;

        s.defenseIndex += 1;
        if (s.defenseIndex < self.config.faceCount)
        {
            return;
        }
    }

    pub fn isDone(self: *const MatchesIterator) bool
    {
        const s = &self.state;
        return s.defenseIndex == self.config.faceCount;
    }

    pub fn next(self: *MatchesIterator) ?ValueIndexMatchPair
    {
        const state = &self.state;
        while (!self.isDone())
        {
            defer
            {
                self.advance();
            }

            const defenseValue = self.defenseCard.values[state.defenseIndex];
            const attackValue = self.attackCard.values[state.attackIndex];

            const defenseWildcard = defenseValue.isWildcard(self.config);
            const attackWildcard = attackValue.isWildcard(self.config);

            if (!defenseWildcard and attackWildcard)
            {
                continue;
            }

            if (defenseWildcard or defenseValue.value() == attackValue.value())
            {
                return ValueIndexMatchPair
                {
                    .response = state.defenseIndex,
                    .attack = state.attackIndex,
                };
            }
        }
        return null;
    }
};

test
{
    var helper = struct
    {
        config: Config = std.mem.zeroInit(Config, .{
            .maxValue = @as(CardSide, @enumFromInt(6)),
            .faceCount = 2,
        }),

        const Self = @This();

        fn init(self: *Self) void
        {
            self.config.init();
        }

        fn wildcard(self: *const Self) u8
        {
            return @intFromEnum(self.config.maxValue);
        }

        const ExpectedResult =  struct
        {
            attack: u8,
            response: u8,
            beats: bool,
        };

        fn doTest(
            self: *const Self,
            attackValues: anytype,
            defenseValues: anytype,
            results: []const ExpectedResult) !void
        {
            const wrappedContext = struct
            {
                attack: Card,
                defense: Card,
                config: *const Config,

                pub fn wrap(self1: @This(), match: ValueIndexMatchPair) ExpectedResult
                {
                    const beats = allDefensesBeatAllAttacks(.{
                        .defense = self1.defense,
                        .attack = self1.attack,
                        .match = match,
                        .config = self1.config,
                    });
                    return .{
                        .attack = match.attack,
                        .response = match.response,
                        .beats = beats,
                    };
                }
            }{
                .attack = createCard(attackValues),
                .defense = createCard(defenseValues),
                .config = &self.config,
            };
            const iter = MatchesIterator
            {
                .attackCard = wrappedContext.attack,
                .defenseCard = wrappedContext.defense,
                .config = &self.config,
            };

            const utils = @import("utils.zig");
            const allocator = std.testing.allocator;
            const wrappedIter = utils.wrapIterMethod(iter, wrappedContext);
            var actualResults = try utils.enumerateAlloc(wrappedIter, allocator);
            // std.debug.print("{any}\n", .{ actualResults.items });
            defer actualResults.deinit(allocator);

            try std.testing.expectEqualDeep(results, actualResults.items);
        }
    }{};
    helper.init();

    try helper.doTest(
        .{ 0, 1 },
        .{ 1, 2 },
        &.{
            .{
                .attack = 1,
                .response = 0,
                .beats = true,
            },
        });
    try helper.doTest(
        .{ 0, 2 },
        .{ helper.wildcard(), 1 },
        &.{
            .{
                .attack = 0,
                .response = 0,
                .beats = false,
            },
            .{
                .attack = 1,
                .response = 0,
                .beats = true,
            },
        });
    try helper.doTest(
        .{ helper.wildcard(), 1 },
        .{ helper.wildcard(), helper.wildcard() },
        &.{
            .{
                .attack = 0,
                .response = 0,
                .beats = true,
            },
            .{
                .attack = 1,
                .response = 0,
                .beats = false,
            },
            .{
                .attack = 0,
                .response = 1,
                .beats = true,
            },
            .{
                .attack = 1,
                .response = 1,
                .beats = false,
            },
        });
    try helper.doTest(
        .{ 0, 1 },
        .{ helper.wildcard(), helper.wildcard() },
        &.{
            .{
                .attack = 0,
                .response = 0,
                .beats = true,
            },
            .{
                .attack = 1,
                .response = 0,
                .beats = true,
            },
            .{
                .attack = 0,
                .response = 1,
                .beats = true,
            },
            .{
                .attack = 1,
                .response = 1,
                .beats = true,
            },
        });
    try helper.doTest(
        .{ 1, 1 },
        .{ 1, 0 },
        &.{
            .{
                .attack = 0,
                .response = 0,
                .beats = false,
            },
            .{
                .attack = 1,
                .response = 0,
                .beats = false,
            },
        });
    try helper.doTest(
        .{ 0, 1 },
        .{ 2, 3 },
        &.{
        });
    try helper.doTest(
        .{ 1, 1 },
        .{ 2, 5 },
        &.{
        });
}

pub const PossibleResponsesIterator = struct
{
    cardInPlay: Card,
    currentHand: *const Hand,
    config: *const Config,

    handCardIndex: usize = 0,
    matchesIterator: MatchesIterator = undefined,

    pub fn init(self: *PossibleResponsesIterator) void
    {
        self.resetMatchesIterator();
    }

    fn isDone(self: *const PossibleResponsesIterator) bool
    {
        if (self.handCardIndex < self.currentHand.cards.items.len)
        {
            return false;
        }

        return true;
    }

    fn resetMatchesIterator(self: *PossibleResponsesIterator) void
    {
        self.matchesIterator = MatchesIterator
        {
            .attackCard = self.cardInPlay,
            .defenseCard = self.currentHand.cards.items[self.handCardIndex],
            .config = self.config,
            .state = .{},
        };
    }

    fn debugPrint(self: *PossibleResponsesIterator, comparisonResult: bool) !void
    {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("{} {s} {} at index {}\n", .{
            self.matchesIterator.defenseCard.asPrintable(self.config),
            if (comparisonResult)
                " > "
            else
                " < ",
            self.matchesIterator.attackCard.asPrintable(self.config),
            self.handCardIndex,
        });
    }

    pub fn next(self: *PossibleResponsesIterator) ?Defense
    {
        while (!self.isDone())
        {
            while (true)
            {
                const defense = self.matchesIterator.defenseCard;
                const attack = self.matchesIterator.attackCard;
                const match = self.matchesIterator.next() orelse break;

                const canDefend = allDefensesBeatAllAttacks(.{
                    .defense = defense,
                    .attack = attack,
                    .match = match,
                    .config = self.config,
                });

                // self.debugPrint(canDefend) catch unreachable;

                if (canDefend)
                {
                    const result = Defense
                    {
                        .handCardIndex = self.handCardIndex,
                        .match = match,
                    };
                    return result;
                }
            }

            self.handCardIndex += 1;
            if (!self.isDone())
            {
                self.resetMatchesIterator();
            }
        }
        return null;
    }
};

pub fn getPossibleDefenses(context: *const GameLogicContext) !PossibleResponsesIterator
{
    const play = &context.state.play;
    if (!play.started())
    {
        return error.NoPlay;
    }
    const cardInPlay = (play.attackCard orelse return error.NoCardInPlay);
    const currentHand = getDefenderHand(context.state);
    var iter = PossibleResponsesIterator
    {
        .cardInPlay = cardInPlay,
        .currentHand = currentHand,
        .config = context.config,
    };
    iter.init();
    return iter;
}

const AllPossibleCardEnumerator = struct
{
    current: Card = std.mem.zeroes(Card),
    config: *const Config,
    done: bool = false,

    pub fn next(self: *AllPossibleCardEnumerator) ?Card
    {
        if (self.done)
        {
            return null;
        }

        const indicesSlice = self.current.getValuesSlice(self.config);
        const currentCard = self.current; 
        var sideIndex: usize = 0;
        for (indicesSlice) |*value|
        {
            const valueAsNum: *u8 = @ptrCast(value);
            valueAsNum.* += 1;

            const maxValue = if (sideIndex == self.config.faceCount - 1)
                    @intFromEnum(self.config.maxValue)
                else
                    @intFromEnum(indicesSlice[sideIndex + 1]);
            if (valueAsNum.* > maxValue)
            {
                valueAsNum.* = 0;
            }
            else
            {
                break;
            }

            sideIndex += 1;
        }
        if (sideIndex == indicesSlice.len)
        {
            self.done = true;
        }
        return currentCard;
    }
};

pub fn resetState(context: *GameLogicContext) !void
{
    const cardsNeededForDeal = context.config.playerCount * context.config.handSize;
    if (cardsNeededForDeal > context.config.deckSize)
    {
        return error.NotEnoughCardsInDeckToDeal;
    }

    // Generate deck
    try context.state.discardPile.ensureTotalCapacityPrecise(
        context.allocator(),
        context.config.deckSize);
    try context.state.drawPile.ensureTotalCapacityPrecise(
        context.allocator(),
        context.config.deckSize);

    {
        const drawPile = &context.state.drawPile.items;
        drawPile.len = context.config.deckSize;
        
        {
            var iter = AllPossibleCardEnumerator
            {
                .config = context.config,
            };
            for (drawPile.*) |*card|
            {
                card.* = iter.next().?;
            }

            std.debug.assert(iter.next() == null);
        }

        // Shuffle deck
        for (drawPile.*) |*card|
        {
            const i = context.randomState.random().int(usize) % drawPile.len;

            const t = card.*;
            card.* = drawPile.*[i];
            drawPile.*[i] = t;
        }
    }

    context.state.discardPile.items.len = 0;
    context.state.turnIndices = .{
        .attacker = 0,
        .defender = 1,
    };
    context.state.play.reset();

    const hands = &context.state.hands;
    {
        const oldPlayerCount = hands.items.len;
        if (context.config.playerCount < oldPlayerCount)
        {
            for (hands.items[context.config.playerCount .. oldPlayerCount]) |*hand|
            {
                hand.cards.deinit(context.allocator());
            }
        }

        try hands.resize(context.allocator(), context.config.playerCount);

        if (oldPlayerCount < context.config.playerCount)
        {
            for (hands.items[oldPlayerCount .. context.config.playerCount]) |*hand|
            {
                hand.* = .{};
            }
        }
    }

    // Deal cards
    for (hands.items) |*hand|
    {
        const handSize = context.config.handSize;

        try hand.cards.resize(context.allocator(), handSize);
        const drawPile = &context.state.drawPile.items;
        for (hand.cards.items, drawPile.*[(drawPile.len - handSize) ..]) |*card, draw|
        {
            card.* = draw;
        }
        drawPile.len -= handSize;
    }
}

fn removeCardFromHand(hand: *Hand, cardIndex: usize) !Card
{
    const cards = &hand.cards;
    if (cardIndex >= cards.items.len)
    {
        return error.InvalidCardIndex;
    }

    const card = cards.orderedRemove(cardIndex);
    return card;
}

fn startPlayCard(context: *GameLogicContext, cardIndex: usize) !void
{
    if (context.state.play.started())
    {
        return error.PlayAlreadyStarted;
    }

    const hand = &context.state.hands.items[context.state.attackerIndex()];
    const card = try removeCardFromHand(hand, cardIndex);
    const play = &context.state.play;

    play.attackCard = card;

    try context.ui.play(.{
        .playerIndex = context.state.attackerIndex(),
        .cardIndex = cardIndex,
        .card = card,
    });
}

fn respond(context: *GameLogicContext, response: Defense) !void
{
    const play = &context.state.play;
    const attackCard = play.attackCard
        orelse return error.MustAttackFirst;

    const responseCard = try removeCardFromHand(
        getDefenderHand(context.state),
        response.handCardIndex);

    play.attackCard = null;

    const allowedValue = attackCard.values[response.match.attack];

    play.nextAllowedValue = allowedValue;
    try play.completePairs.append(context.allocators.play.allocator(), .{
        .attack = attackCard,
        .response = responseCard,
    });

    try context.ui.respond(.{
        .playerIndex = context.state.defenderIndex(),
        .response = response,
        .card = responseCard,
    });
}

pub fn getDefenderHand(state: *const GameState) *Hand
{
    const defenderHand = &state.hands.items[state.defenderIndex()];
    return defenderHand;
}

fn isDefenderAbleToRespond(state: *const GameState) bool
{
    const defenderHand = getDefenderHand(state);
    return (defenderHand.cards.items.len != 0);
}

fn throwIntoPlay(context: *GameLogicContext, throw: ThrowAttack) !void
{
    if (!isDefenderAbleToRespond(context.state))
    {
        return error.DefenderWontBeAbleToRespond;
    }

    const hand = &context.state.hands.items[throw.attackerIndex];
    const card = try removeCardFromHand(hand, throw.handCardIndex);
    blk: {
        const nextAllowedValue = context.state.play.nextAllowedValue 
            orelse return error.NextAllowedValueUninitialized;
        for (card.getValuesSlice(context.config)) |side|
        {
            if (side == nextAllowedValue)
            {
                break :blk;
            }
        }
        unreachable;
    }
    context.state.play.attackCard = card;

    try context.ui.throwIntoPlay(.{
        .playerIndex = throw.attackerIndex,
        .card = card,
    });
}

pub fn findNextNotDonePlayerIndex(context: *GameLogicContext, startIndex: u8, stopIndex: u8) ?u8
{
    var a = startIndex;
    while (true)
    {
        a = (a +% 1) % context.config.playerCount;
        const hand = getHand(context.state, a);
        if (a == stopIndex)
        {
            return null;
        }

        if (hand.cards.items.len != 0)
        {
            return a;
        }
    }
}

pub const NextPlayerIterator = struct
{
    options: Options,
    currentIndex: u8,
    repeatCount: usize,

    const Options = struct
    {
        stopIndex: u8,
        playerCount: u8,
        stopAtRepeatCount: usize,
    };

    const CreationOptions = struct
    {
        startIndex: u8,
        stopIndex: ?u8 = null,
        config: *const Config,
    };

    pub fn create(options_: CreationOptions) NextPlayerIterator
    {
        const stopIndex = options_.stopIndex orelse options_.startIndex;
        const increaseRepeatCount = if (options_.stopIndex != null) false else true;
        return .{
            .options = .{
                .stopIndex = stopIndex,
                .playerCount = options_.config.playerCount,
                .stopAtRepeatCount = if (increaseRepeatCount) 1 else 0,
            },
            .currentIndex = options_.startIndex,
            .repeatCount = 0,
        };
    }

    pub fn next(self: *NextPlayerIterator) ?u8
    {
        defer
        {
            self.currentIndex = (self.currentIndex +% 1) % self.options.playerCount;
        }
        if (self.currentIndex != self.options.stopIndex)
        {
            return self.currentIndex;
        }

        defer self.repeatCount += 1;
        if (self.repeatCount < self.options.stopAtRepeatCount)
        {
            return self.currentIndex;
        }

        return null;
    }
};

fn maybeMoveTurnToNextPlayer(context: *GameLogicContext) !void
{
    moveTurnToNextPlayer(context) catch |err|
    {
        switch (err)
        {
            error.GameOver => {},
            else => |e| return e,
        }
    };
}

fn moveTurnToNextPlayer(context: *GameLogicContext) !void
{
    var newAttacker = context.state.defenderIndex();
    const a = &newAttacker;
    a.* = findNextNotDonePlayerIndex(context, a.*, a.*)
        orelse return error.GameOver;
    const newDefender = findNextNotDonePlayerIndex(context, a.*, a.*)
        orelse return error.GameOver;

    const players = .{ 
        .attacker = newAttacker,
        .defender = newDefender,
    };
    context.state.turnIndices = players;

    try context.ui.passTurn(.{
        .players = players,
    });
}

// Returns the moved slice
fn movePlayPairsInto(
    allocator: std.mem.Allocator,
    play: *PlayState,
    into: *std.ArrayListUnmanaged(Card)) ![]const Card
{
    const added = try into.addManyAsSlice(
        allocator,
        play.completePairs.items.len * 2);

    std.debug.assert(added.len > 0);

    {
        var i: usize = 0;
        for (play.completePairs.items) |*pair|
        {
            added[i] = pair.attack;
            i += 1;
            added[i] = pair.response;
            i += 1;
        }
    }

    return added;
}

fn endPlay(context: *GameLogicContext) !void
{
    const play = &context.state.play;
    if (!play.started())
    {
        return error.CannotEndEmptyPlay;
    }

    if (play.attackCard != null)
    {
        return error.CannotEndUnrespondedPlay;
    }

    const moved = try movePlayPairsInto(
        context.allocator(),
        play,
        &context.state.discardPile);

    try context.ui.moveIntoDrawPile(.{
        .cards = moved,
    });
    try resetPlay(context);
}

fn resetPlay(context: *GameLogicContext) !void
{
    context.state.play.reset();
    try context.ui.resetPlay(.{});

    _ = context.allocators.play.reset(.retain_capacity);
}

fn redraw(context: *GameLogicContext) !void
{
    const drawPile = &context.state.drawPile;
    if (drawPile.items.len == 0)
    {
        return;
    }

    const startIndex = context.state.defenderIndex();

    var addedList = std.ArrayList(UIObject.PlayerDraw)
        .init(context.allocators.event.allocator());
    // defer addedList.deinit();

    // This has to be smarter, because it has to evenly distribute the cards.
    var playerIter = NextPlayerIterator.create(.{
        .startIndex = startIndex,
        .config = context.config,
    });
    while (drawPile.items.len > 0)
    {
        const currentIndex = playerIter.next() orelse break;
        const hand = &context.state.hands.items[currentIndex];
        if (hand.cards.items.len >= context.config.handSize)
        {
            continue;
        }

        const cardCountWouldLikeToAdd = context.config.handSize - hand.cards.items.len;
        const availableCardCount = drawPile.items.len;
        const actuallyAddedCardCount = @min(availableCardCount, cardCountWouldLikeToAdd);
        const removedFromIndex = drawPile.items.len - actuallyAddedCardCount;
        const removedSlice = drawPile.items[removedFromIndex ..];
        const addedSlice = try hand.cards.addManyAsSlice(context.allocator(), actuallyAddedCardCount);
        for (removedSlice, addedSlice) |drawn, *into|
        {
            into.* = drawn;
        }
        drawPile.items.len = removedFromIndex;

        try addedList.append(.{
            .playerIndex = currentIndex,
            .addedCards = addedSlice,
        });
    }

    if (addedList.items.len > 0)
    {
        try context.ui.redraw(.{
            .draws = &addedList,
        });
    }
}

fn takePlayIntoHand(context: *GameLogicContext) !void
{
    const play = &context.state.play;
    if (!play.started())
    {
        return error.PlayMustBeStartedToTake;
    }

    const hand = &context.state.hands.items[context.state.defenderIndex()];
    if (play.attackCard) |a|
    {
        std.debug.print("Adding {} to hand\n", .{ a.asPrintable(context.config) });
        try hand.cards.append(context.allocator(), a);
    }

    if (play.completePairs.items.len > 0)
    {
        // TODO: Add take event
        _ = try movePlayPairsInto(context.allocator(), play, &hand.cards);
    }

    try resetPlay(context);
}

fn gameStateHelper(context: *GameLogicContext) PlayOption
{
    if (!context.state.play.started())
    {
        return .InitialAttack;
    }

    if (context.state.play.attackCard != null)
    {
        return .Defense;
    }

    return .ThrowAttack;
}

pub const PossibleAttackersIterator = struct
{
    context: *GameLogicContext,
    currentIndex: u8 = undefined,
    done: bool = false,

    pub fn create(context: *GameLogicContext) PossibleAttackersIterator
    {
        var result = PossibleAttackersIterator
        {
            .context = context,
        };
        result.currentIndex = result.initialIndex();
        return result;
    }

    fn initialIndex(self: *const PossibleAttackersIterator) u8
    {
        return self.context.state.attackerIndex();
    }

    pub fn next(self: *PossibleAttackersIterator) ?u8
    {
        if (self.done)
        {
            return null;
        }

        const result = self.currentIndex;

        while (true)
        {
            const nextIndex = findNextNotDonePlayerIndex(
                self.context,
                self.currentIndex,
                self.initialIndex());
            if (nextIndex) |i|
            {
                self.currentIndex = i;

                if (i == self.context.state.defenderIndex())
                {
                    continue;
                }
            }
            else
            {
                self.done = true;
            }

            return result;
        }
    }
};

pub const ThrowAttackCardIndexIterator = struct
{
    allowedValue: CardSide,
    hand: *const Hand,
    cardIndex: usize = 0,
    config: *const Config,

    pub fn fromPlayerIndex(context: *GameLogicContext, playerIndex: u8) ThrowAttackCardIndexIterator
    {
        return .{
            .allowedValue = context.state.play.nextAllowedValue.?,
            .hand = &context.state.hands.items[playerIndex],
            .config = context.config,
        };
    }

    pub fn next(self: *ThrowAttackCardIndexIterator) ?usize
    {
        const cards = self.hand.cards.items;
        while (self.cardIndex < cards.len)
        {
            defer
            {
                self.cardIndex += 1;
            }

            const card = cards[self.cardIndex];
            for (card.getValuesSlice(self.config)) |v|
            {
                if (self.allowedValue == v)
                {
                    return self.cardIndex;
                }
            }
        }
        return null;
    }
};

pub fn getHand(state: *const GameState, playerIndex: u8) *Hand
{
    return &state.hands.items[playerIndex];
}

pub fn getAttackerHand(state: *const GameState) *Hand
{
    return getHand(state, state.attackerIndex());
}

pub const PlayerThrowAttackOption = struct
{
    attackerIndex: usize,
    cardIndex: usize,
};

pub const AllPlayersThrowAttackIterator = struct
{
    attackers: PossibleAttackersIterator,
    throw: ?ThrowAttackCardIndexIterator = null,

    pub fn create(context: *GameLogicContext) AllPlayersThrowAttackIterator
    {
        const result = AllPlayersThrowAttackIterator
        {
            .attackers = PossibleAttackersIterator.create(context),
        };
        return result;
    }

    pub fn next(self: *AllPlayersThrowAttackIterator) ?PlayerThrowAttackOption
    {
        if (self.throw == null)
        {
            const newThrow = self.attackers.next();
            if (newThrow) |playerIndex|
            {
                const context = self.attackers.context;
                self.throw = ThrowAttackCardIndexIterator.fromPlayerIndex(context, playerIndex); 
            }
            else
            {
                return null;
            }
        }

        const throw_ = self.throw.?;
        if (throw_.next()) |cardIndex|
        {
            return .{
                .attackerIndex = self.attackers.currentIndex,
                .cardIndex = cardIndex,
            };
        }

        self.throw = null;
        return null;
    }
};


pub const PlayOption = enum
{
    Defense,
    InitialAttack,
    ThrowAttack,
    None,
};

pub const PlayOptionsIterator = union(PlayOption)
{
    Defense: PossibleResponsesIterator,
    InitialAttack: Hand,
    ThrowAttack: AllPlayersThrowAttackIterator,
    None: void,
};

pub fn getIteratorFor(context: *const GameLogicContext, option: PlayOption) PlayOptionsIterator
{
    return switch (option)
    {
        .ThrowAttack => .{ .ThrowAttack = AllPlayersThrowAttackIterator.create(context) },
        .Defenses => .{ .Defenses = getPossibleDefenses(context) catch unreachable },
        .InitialAttack => .{ .InitialAttack = getAttackerHand(context) },
        .None => .None,
    };
}

fn endPlayAndTurn(context: *GameLogicContext) !void
{
    try endPlay(context);
    try redraw(context);
    try maybeMoveTurnToNextPlayer(context);
}

fn takeAndEndPlayAndTurn(context: *GameLogicContext) !void
{
    try takePlayIntoHand(context);
    try redraw(context);
    try maybeMoveTurnToNextPlayer(context);
}

fn endPlayAndTurnIfDefenderCantRespondAnymore(context: *GameLogicContext) !void
{
    if (isDefenderAbleToRespond(context.state))
    {
        return;
    }

    endPlayAndTurn(context) catch |err|
    {
        switch (err)
        {
            error.GameOver => return,
            else => return err,
        }
    };
}

fn maybeEndGame(context: *GameLogicContext) !bool
{
    const endState = getCompletionStatus(context.state);
    if (endState != .Incomplete)
    {
        try context.ui.gameOver(.{
            .result = endState,
        });
        return true;
    }

    return false;
}

fn processEvents(context: *GameLogicContext) !bool
{
    const events = &context.eventQueue.events;
    defer events.clearRetainingCapacity();

    if (try maybeEndGame(context))
    {
        return true;
    }

    // We have to do index iteration because new events can be
    // added into the queue while we're iterating.
    var i: usize = 0;
    while (i < events.items.len) : (i += 1)
    {
        defer _ = context.allocators.event.reset(.retain_capacity);

        const ev = events.items[i];
        switch (ev)
        {
            .Play => |play|
            {
                try startPlayCard(context, play.handCardIndex);
            },
            .Response => |response|
            {
                switch (response)
                {
                    .Take => 
                    {
                        try takeAndEndPlayAndTurn(context);
                    },
                    .Defense => |v|
                    {
                        try respond(context, v);
                        try endPlayAndTurnIfDefenderCantRespondAnymore(context);
                    },
                }
            },
            .Throw => |throw|
            {
                switch (throw)
                {
                    .Skip => try endPlayAndTurn(context),
                    .Throw => |v| try throwIntoPlay(context, v),
                }
            },
        }

        if (try maybeEndGame(context))
        {
            return true;
        }
    }

    return false;
}

pub fn gameLogicLoop(context: *GameLogicContext) !bool
{
    if (try processEvents(context))
    {
        return true;
    }

    const playOption = gameStateHelper(context);
    try context.ui.setOptions(.{
        .playOption = playOption,
    });

    return false;
}
