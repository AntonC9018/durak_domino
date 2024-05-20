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

    pub fn print(self: Card, writer: anytype, config: *const Config) !void
    {
        try printWithHighlightAt(self, writer, config, null);
    }

    pub fn printWithHighlightAt(
        self: Card,
        writer: anytype,
        config: *const Config,
        highlightIndex: ?u8) !void
    {
        const values = self.getValuesSlice(config);
        for (0 .., values) |i, v|
        {
            if (i != 0)
            {
                try writer.print("-", .{});
            }

            const shouldHighlight = if (highlightIndex) |h| i == h else false;
            if (shouldHighlight)
            {
                try writer.print("*", .{});
            }

            if (v == config.maxValue)
            {
                try writer.print(" ", .{});
            }
            else
            {
                try writer.print("{}", .{ v });
            }

            if (shouldHighlight)
            {
                try writer.print("*", .{});
            }
        }
    }
};

pub fn createCard(values: anytype) Card
{
    comptime std.debug.assert(values.len > maxSideCount);
    var card = std.mem.zeroes(Card);
    for (card.values[0 .. values.len], &values) |*to, from|
    {
        to.* = from;
    }
    return card;
}

pub const CardSide = enum(u8) { _ };

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


pub const GameLogicContext = struct
{
    config: *Config,
    state: *GameState,
    allocator: std.mem.Allocator,
    randomState: std.rand.Xoshiro256,
    ui: UIObject,
    eventQueue: EventQueue,
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
        self.completePairs.items.len = 0;
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

pub fn allDefensesBeatAllAttacks(p: struct
    {
        defense: Card,
        attack: Card,
        match: ValueIndexMatchPair,
        config: *const Config,
    }) bool
{
    std.debug.assert(p.config.faceCount == 2);

    const otherAttackIndex = (p.match.attack +% 1) % 2;
    const otherAttackValue = p.attack.values[otherAttackIndex];

    const otherDefenseIndex = (p.match.response +% 1) % 2;
    const otherDefenseValue = p.defense.values[otherDefenseIndex];

    if (otherDefenseValue > otherAttackValue)
    {
        return true;
    }
    return false;
}

test "DefenseBeatsAttack"
{
    var config = Config
    {
        .faceCount = 2,
        .maxValue = 2,
    };
    config.init();
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
        const s = &self.state;
        if (s.matchingWildcards)
        {
            s.defenseIndex += 1;
            return;
        }

        s.defenseIndex += 1;
        if (s.defenseIndex < self.config.faceCount)
        {
            return;
        }

        s.defenseIndex = 0;

        s.attackIndex += 1;
        if (s.attackIndex < self.config.faceCount)
        {
            return;
        }

        s.matchingWildcards = true;
        s.attackIndex = 0;
        s.defenseIndex = 0;
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
            if (state.matchingWildcards)
            {
                if (defenseValue != self.config.maxValue)
                {
                    continue;
                }

                const largestIndex = largestIndex:
                {
                    var maxIndex: usize = if (state.defenseIndex == 0) 1 else 0;
                    for ((maxIndex + 1) .., self.attackCard.getValuesSlice(self.config)) |i, b|
                    {
                        if (i == state.defenseIndex)
                        {
                            continue;
                        }
                        const a = self.defenseCard.values[maxIndex];
                        if (a > b)
                        {
                            maxIndex = i;
                        }
                    }
                    break :largestIndex maxIndex;
                };

                return .{
                    .response = state.defenseIndex,
                    .attack = @intCast(largestIndex),
                };
            }
            else
            {
                const attackValue = self.attackCard.values[state.attackIndex];

                if (attackValue != defenseValue)
                {
                    continue;
                }

                const potentialResult = ValueIndexMatchPair
                {
                    .response = state.defenseIndex,
                    .attack = state.attackIndex,
                };

                return potentialResult;
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
            .maxValue = 3,
            .faceCount = 2,
        }),

        const Self = @This();

        fn init(self: *Self) void
        {
            self.config.init();
        }

        fn wildcard(self: *const Self) CardSide
        {
            return self.config.maxValue;
        }

        fn doTest(
            self: *const Self,
            attackValues: anytype,
            defenseValues: anytype,
            results: []const struct
            {
                attack: u8,
                response: u8,
                beats: bool,
            }) !void
        {
            const attack = createCard(attackValues);
            const defense = createCard(defenseValues);

            const equal = std.testing.expectEqual;

            var iter = MatchesIterator
            {
                .attackCard = attack,
                .defenseCard = defense,
                .config = &self.config,
            };

            for (results) |r|
            {
                const a = iter.next().?;
                try equal(r.attack, a.attack);
                try equal(r.response, a.response);
                const beats = allDefensesBeatAllAttacks(.{
                    .attack = attack,
                    .defense = defense,
                    .config = &self.config,
                    .match = a,
                });
                try equal(r.beats, beats);
            }

            try equal(null, iter.next());
        }
    }{};
    helper.init();

    try helper.doTest(
        .{ 0, 1 },
        .{ 1, 2 },
        .{
            .{
                .attack = 1,
                .response = 0,
                .beats = true,
            },
        });
    try helper.doTest(
        .{ 0, 2 },
        .{ helper.wildcard(), 1 },
        .{
            .{
                .attack = 1,
                .response = 0,
                .beats = true,
            },
        });
    try helper.doTest(
        .{ helper.wildcard(), 1 },
        .{ helper.wildcard(), helper.wildcard() },
        .{
            .{
            },
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
        try self.matchesIterator.defenseCard.print(stderr, self.config);
        if (comparisonResult)
        {
            try stderr.print(" > ", .{});
        }
        else
        {
            try stderr.print(" < ", .{});
        }
        try self.matchesIterator.attackCard.print(stderr, self.config);
        try stderr.print("\n", .{});
    }

    pub fn next(self: *PossibleResponsesIterator) ?Defense
    {
        while (!self.isDone())
        {
            while (self.matchesIterator.next()) |n|
            {
                const canDefend = allDefensesBeatAllAttacks(.{
                    .defense = self.matchesIterator.defenseCard,
                    .attack = self.matchesIterator.attackCard,
                    .match = n,
                    .config = self.config,
                });

                self.debugPrint(canDefend) catch unreachable;

                if (canDefend)
                {
                    return .{
                        .handCardIndex = self.handCardIndex,
                        .match = n,
                    };
                }
            }

            self.resetMatchesIterator();
            self.handCardIndex += 1;
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

pub const AllPossibleCardEnumerator = struct
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
        context.allocator,
        context.config.deckSize);
    try context.state.drawPile.ensureTotalCapacityPrecise(
        context.allocator,
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
                hand.cards.deinit(context.allocator);
            }
        }

        try hands.resize(context.allocator, context.config.playerCount);

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

        try hand.cards.resize(context.allocator, handSize);
        const drawPile = &context.state.drawPile.items;
        for (hand.cards.items, drawPile.*[(drawPile.len - handSize) ..]) |*card, draw|
        {
            card.* = draw;
        }
        drawPile.len -= handSize;
    }
}

pub fn removeCardFromHand(hand: *Hand, cardIndex: usize) !Card
{
    const cards = &hand.cards;
    if (cardIndex >= cards.items.len)
    {
        return error.InvalidCardIndex;
    }

    const card = cards.orderedRemove(cardIndex);
    return card;
}

pub fn startPlayCard(context: *GameLogicContext, cardIndex: usize) !void
{
    if (context.state.play.started())
    {
        return error.PlayAlreadyStarted;
    }

    const hand = &context.state.hands.items[context.state.attackerIndex()];
    const card = try removeCardFromHand(hand, cardIndex);
    const play = &context.state.play;
    play.reset();

    play.attackCard = card;

    try context.ui.play(.{
        .playerIndex = context.state.attackerIndex(),
        .cardIndex = cardIndex,
        .card = card,
    });
}

pub fn respond(context: *GameLogicContext, response: Defense) !void
{
    const play = &context.state.play;
    const attackCard = play.attackCard
        orelse return error.MustAttackFirst;

    const responseCard = try removeCardFromHand(
        getDefenderHand(context.state),
        response.handCardIndex);

    play.attackCard = null;

    const allowedValue = attackCard.values[response.match.attack];
    std.debug.print("Allowed: {}, Response: {}\n", .{allowedValue, responseCard.values[response.match.response] });

    play.nextAllowedValue = allowedValue;
    try play.completePairs.append(context.allocator, .{
        .attack = attackCard,
        .response = responseCard,
    });

    try context.ui.respond(.{
        .playerIndex = context.state.defenderIndex(),
        .response = response,
    });
}

pub fn getDefenderHand(state: *const GameState) *Hand
{
    const defenderHand = &state.hands.items[state.defenderIndex()];
    return defenderHand;
}

pub fn isDefenderAbleToRespond(state: *const GameState) bool
{
    const defenderHand = getDefenderHand(state);
    return (defenderHand.cards.items.len == 0);
}

pub fn throwIntoPlay(context: *GameLogicContext, throw: ThrowAttack) !void
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
        if (hand.cards.items.len != 0)
        {
            return a;
        }

        if (a == stopIndex)
        {
            return null;
        }
    }
}

pub fn moveTurnToNextPlayer(context: *GameLogicContext) !void
{
    var newAttacker = context.state.defenderIndex();
    const a = &newAttacker;
    const initialAttacker = a.*;
    a.* = findNextNotDonePlayerIndex(context, a.*, a.*)
        orelse return error.GameOver;
    const newDefender = findNextNotDonePlayerIndex(context, a.*, initialAttacker)
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

pub fn movePlayPairsInto(
    allocator: std.mem.Allocator,
    play: *PlayState,
    into: *std.ArrayListUnmanaged(Card),
    ui: UIObject) !void
{
    const added = try into.addManyAsSlice(
        allocator,
        play.completePairs.items.len * 2);

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

    try ui.moveIntoDrawPile(.{
        .cards = added,
    });
}

pub fn endPlay(context: *GameLogicContext) !void
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

    try movePlayPairsInto(
        context.allocator,
        play,
        &context.state.discardPile,
        context.ui);

    play.reset();

    try context.ui.resetPlay(.{});
}

pub fn redraw(context: *GameLogicContext) !void
{
    const drawPile = &context.state.drawPile;
    if (drawPile.items.len == 0)
    {
        return;
    }

    const startIndex = context.state.defenderIndex();
    var currentIndex = startIndex;

    var addedList = std.ArrayList(UIObject.PlayerDraw).init(context.allocator);
    defer addedList.deinit();

    while (drawPile.items.len > 0)
    {
        const hand = &context.state.hands.items[currentIndex];
        if (hand.cards.items.len >= context.config.handSize)
        {
            currentIndex = (currentIndex +% 1) % context.config.playerCount;

            if (currentIndex == startIndex)
            {
                break;
            }
        }

        const cardCountWouldLikeToAdd = context.config.handSize - hand.cards.items.len;
        const availableCardCount = drawPile.items.len;
        const actuallyAddedCardCount = @min(availableCardCount, cardCountWouldLikeToAdd);
        const removedFromIndex = drawPile.items.len - actuallyAddedCardCount;
        const removedSlice = drawPile.items[removedFromIndex ..];
        const addedSlice = try hand.cards.addManyAsSlice(context.allocator, actuallyAddedCardCount);
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

pub fn takePlayIntoHand(context: *GameLogicContext) !void
{
    const play = &context.state.play;
    if (!play.started())
    {
        return error.PlayMustBeStartedToTake;
    }

    const hand = &context.state.hands.items[context.state.defenderIndex()];
    if (play.attackCard) |a|
    {
        try hand.cards.append(context.allocator, a);
    }

    try movePlayPairsInto(context.allocator, play, &hand.cards, context.ui);
    play.reset();
}

pub fn gameStateHelper(context: *GameLogicContext) PlayOption
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

pub fn getCardsAllowedForThrow(context: *GameLogicContext, playerIndex: u8) ThrowAttackOptionsIterator
{
    return .{
        .allowedValue = context.state.play.nextAllowedValue.?,
        .hand = &context.state.hands.items[playerIndex],
        .config = context.config,
    };
}

pub const ThrowAttackOptionsIterator = struct
{
    allowedValue: CardSide,
    hand: *const Hand,
    cardIndex: usize = 0,
    config: *const Config,

    pub fn next(self: *ThrowAttackOptionsIterator) ?usize
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
    throw: ?ThrowAttackOptionsIterator = null,

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
                self.throw = getCardsAllowedForThrow(context, playerIndex); 
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

pub fn endPlayAndTurn(context: *GameLogicContext) !void
{
    try endPlay(context);
    try redraw(context);
    try moveTurnToNextPlayer(context);
}

pub fn takeAndEndTurnIfDefenderCantBeat(context: *GameLogicContext) !void
{
    if (isDefenderAbleToRespond(context.state))
    {
        return;
    }

    try takePlayIntoHand(context);
    endPlayAndTurn(context) catch |err|
    {
        switch (err)
        {
            error.GameOver => return,
            else => return err,
        }
    };
}

pub fn maybeEndGame(context: *GameLogicContext) !bool
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

pub fn gameLogicLoop(context: *GameLogicContext) !bool
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
        const ev = events.items[i];
        switch (ev)
        {
            .Play => |play|
            {
                try startPlayCard(context, play.handCardIndex);
                try takeAndEndTurnIfDefenderCantBeat(context);
            },
            .Response => |response|
            {
                switch (response)
                {
                    .Take => 
                    {
                        try takePlayIntoHand(context);
                    },
                    .Response => |v|
                    {
                        try respond(context, v);
                    },
                }
            },
            .Throw => |throw|
            {
                switch (throw)
                {
                    .Skip => try endPlayAndTurn(context),
                    .Throw => |v| 
                    {
                        try throwIntoPlay(context, v);
                        try takeAndEndTurnIfDefenderCantBeat(context);
                    }
                }
            },
        }

        if (try maybeEndGame(context))
        {
            return true;
        }
    }

    const playOption = gameStateHelper(context);
    try context.ui.setOptions(.{
        .playOption = playOption,
    });

    return false;
}
