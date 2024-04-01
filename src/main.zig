const std = @import("std");

const maxSideCount = 8;

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

pub const CardSide = u8;

pub const Hand = struct
{
    cards: std.ArrayListUnmanaged(Card) = .{},
};

pub const Config = struct
{
    maxValue: u8,
    faceCount: u8,
    handSize: u8,
    deckSize: u32 = undefined,
    playerCount: u8,

    pub fn numValuesForFace(self: *Config) u8
    {
        return self.maxValue + 1;
    }

    pub fn init(self: *Config) void
    {
        const numSelectionForEachFace = self.maxValue + 1;
        const numFaces = self.faceCount;
        const numCombinations = std.math.powi(u32, numSelectionForEachFace, numFaces) catch unreachable;
        // Do not count duplicates.
        self.deckSize = numCombinations / 2;
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
    turnIndices: CurrentPlayers = .{
        .attacker = 0,
        .defender = 1,
    },
    play: Play = .{},

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
};

pub const CardPair = struct
{
    attack: Card,
    response: Card,
};

pub const Play = struct
{
    attackCard: ?Card = null,
    completePairs: std.ArrayListUnmanaged(CardPair) = .{},
    nextAllowedValue: ?CardSide = null,

    pub fn started(self: *const Play) bool
    {
        return self.attackCard != null or self.completePairs.items.len != 0;
    }

    pub fn reset(self: *Play) void
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

    const areAllEmpty: bool = areAllEmpty:
    {
        for (game.hands.items) |*hand|
        {
            if (hand.cards.items.len != 0)
            {
                break :areAllEmpty false;
            }
        }
        break :areAllEmpty true;
    };
    if (areAllEmpty)
    {
        return .{ .Tie = {} };
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
    } orelse return .{ .Incomplete = {} };

    for (game.hands.items[firstNonEmptyIndex ..]) |*hand|
    {
        if (hand.cards.items.len != 0)
        {
            return .{ .Incomplete = {} };
        }
    }
    return  .{ .Lose = @intCast(firstNonEmptyIndex) };
}

pub fn getNextPlayer(game: *const GameState) ?u8
{
    var next = game.attackerIndex() +% 1;
    while (true)
    {
        if (game.hands.items[next].cards.items.len != 0)
        {
            return @intCast(next);
        }
        if (game.attackerIndex() == next)
        {
            return null;
        }

        next %= 1;
    }
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

pub const PossibleResponse = struct
{
    handCardIndex: usize,
    match: ValueIndexMatchPair,
};

pub fn allDefensesBeatAllAttacks(p: struct
    {
        target: Card,
        play: Card,
        match: ValueIndexMatchPair,
        config: *const Config,
    }) bool
{
    std.debug.assert(p.config.faceCount == 2);

    const otherAttackIndex = (p.match.attack +% 1) % 2;
    const otherAttackValue = p.play.values[otherAttackIndex];

    const otherDefenseIndex = (p.match.response +% 1) % 2;
    const otherDefenseValue = p.target.values[otherDefenseIndex];

    if (otherDefenseValue > otherAttackValue)
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

// pub fn isMatchValid(match: ValueIndexMatchPair) bool
// {
// }
//

pub const MatchesIterator = struct
{
    state: MatchesIteratorState,
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

        if (s.defenseIndex < self.config.faceCount - 1)
        {
            s.defenseIndex += 1;
            return;
        }

        s.defenseIndex = 0;

        if (s.attackIndex < self.config.faceCount - 1)
        {
            s.attackIndex += 1;
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
                    var maxIndex: usize = if (state.attackIndex == 0) 1 else 0;
                    for ((maxIndex + 1) .., self.attackCard.getValuesSlice(self.config)) |i, b|
                    {
                        if (i == state.defenseIndex)
                        {
                            continue;
                        }
                        const a = self.attackCard.values[maxIndex];
                        if (b > a)
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
                const playValue = self.attackCard.values[state.attackIndex];

                if (playValue != defenseValue)
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

    pub fn isDone(self: *const PossibleResponsesIterator) bool
    {
        if (self.handCardIndex != self.currentHand.cards.items.len)
        {
            return false;
        }

        return true;
    }

    pub fn resetMatchesIterator(self: *PossibleResponsesIterator) void
    {
        self.matchesIterator = MatchesIterator
        {
            .attackCard = self.cardInPlay,
            .defenseCard = self.currentHand.cards.items[self.handCardIndex],
            .config = self.config,
            .state = .{},
        };
    }

    pub fn next(self: *PossibleResponsesIterator) ?PossibleResponse
    {
        while (!self.isDone())
        {
            while (self.matchesIterator.next()) |n|
            {
                if (allDefensesBeatAllAttacks(.{
                        .target = self.matchesIterator.defenseCard,
                        .play = self.matchesIterator.attackCard,
                        .match = n,
                        .config = self.config,
                    }))
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

pub fn getPossibleResponses(context: *const GameLogicContext) !PossibleResponsesIterator
{
    const play = &context.state.play;
    if (!play.started())
    {
        return error.NoPlay;
    }
    const cardInPlay = (play.attackCard orelse return error.NoCardInPlay);
    const currentHand = &context.state.hands.items[context.state.defenderIndex()];
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
    current: Card,
    indexCount: u8,
    maxValue: CardSide,
    done: bool = false,

    pub fn next(self: *AllPossibleCardEnumerator) ?Card
    {
        if (self.done)
        {
            return null;
        }

        const indicesSlice = self.current.values[0 .. self.indexCount];
        const currentCard = self.current; 
        for (indicesSlice) |*i|
        {
            i.* += 1;
            if (i.* == self.maxValue)
            {
                i.* = 0;
            }
            else
            {
                return currentCard;
            }
        }
        self.done = true;
        return currentCard;
    }
};

pub fn convertIndexToCard(index: usize, config: *Config) Card
{
    var result = std.mem.zeroes(Card);
    var currentRemaining = index;
    for (0 .. config.faceCount) |i|
    {
        const faceIndex = config.faceCount - 1 - i;
        result.values[faceIndex] = @intCast(currentRemaining % config.numValuesForFace());
        currentRemaining /= config.numValuesForFace();
    }
    return result;
}

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
        for (0 .., drawPile.*) |i, *card|
        {
            card.* = convertIndexToCard(i, context.config);
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
        try hand.cards.resize(context.allocator, context.config.handSize);
        const drawPile = &context.state.drawPile.items;
        for (hand.cards.items, drawPile.*[(drawPile.len - context.config.handSize) ..]) |*card, draw|
        {
            card.* = draw;
        }
        drawPile.len -= context.config.handSize;
    }
}

pub fn removeCardFromHand(hand: *Hand, cardIndex: usize) !Card
{
    const cards = &hand.cards;
    if (cardIndex >= cards.items.len - 1)
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
}

pub fn respond(context: *GameLogicContext, response: PossibleResponse) !void
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

pub fn throwIntoPlay(context: *GameLogicContext, playerIndex: u8, cardIndex: usize) !void
{
    if (!isDefenderAbleToRespond(context.state))
    {
        return error.DefenderWontBeAbleToRespond;
    }

    const hand = &context.state.hands.items[playerIndex];
    const card = try removeCardFromHand(hand, cardIndex);
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
}

pub fn findNextNotDonePlayerIndex(context: *GameLogicContext, startIndex: u8, stopIndex: u8) ?u8
{
    var a = startIndex;
    while (true)
    {
        a = (a +% 1) % context.config.playerCount;
        if (context.state.hands.items[a].cards.items.len != 0)
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

    context.state.turnIndices = .{ 
        .attacker = newAttacker,
        .defender = newDefender,
    };
}

pub fn movePlayPairsInto(
    allocator: std.mem.Allocator,
    play: *Play,
    into: *std.ArrayListUnmanaged(Card)) !void
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
        &context.state.discardPile);

    play.reset();
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
    while (true)
    {
        const hand = &context.state.hands.items[currentIndex];
        if (hand.cards.items.len >= context.config.handSize)
        {
            currentIndex = (currentIndex +% 1) % context.config.playerCount;

            if (currentIndex == startIndex)
            {
                return;
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

        if (drawPile.items.len == 0)
        {
            return;
        }
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

    try movePlayPairsInto(context.allocator, play, &hand.cards);
    play.reset();
}

pub fn gameStateHelper(context: *GameLogicContext)
    enum
    {
        Play,
        Respond,
        ThrowIntoPlayOrEnd,
    }
{
    if (!context.state.play.started())
    {
        return .Play;
    }

    if (context.state.play.attackCard != null)
    {
        return .Respond;
    }

    return .ThrowIntoPlayOrEnd;
}

pub const PossibleAttackersIterator = struct
{
    context: *GameLogicContext,
    currentIndex: u8 = undefined,
    done: bool = false,

    pub fn init(self: *PossibleAttackersIterator) void
    {
        self.currentIndex = self.initialIndex();
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

pub fn endPlayAndTurn(context: *GameLogicContext) !void
{
    try endPlay(context);
    try redraw(context);
    try moveTurnToNextPlayer(context);
}

pub fn getCardsAllowedForThrow(context: *GameLogicContext, playerIndex: u8) OptionsIterator
{
    return .{
        .allowedValue = context.state.play.nextAllowedValue.?,
        .hand = &context.state.hands.items[playerIndex],
        .config = context.config,
    };
}

pub const OptionsIterator = struct
{
    allowedValue: CardSide,
    hand: *const Hand,
    cardIndex: usize = 0,
    config: *const Config,

    pub fn next(self: *OptionsIterator) ?usize
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

const UiContext = struct
{
    attackersIterator: ?PossibleAttackersIterator,
};

fn showGameOver(context: *GameLogicContext, cout: anytype) !bool
{
    const endState = getCompletionStatus(context.state);
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
            Empty: void,
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
            return .{ .Empty = {} };
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
                return .{ .Empty = {} };
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
        const Self = @This();

        ptr: [*]T,
        rangeIter: RangeIter,

        pub fn next(self: *Self) ?*T
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
    hand: *const Hand,
    config: *const Config,
};

const CardInHand = struct
{
    context: CardInHandContext,
    cardIndex: usize,

    pub fn card(self: *const CardInHand) Card
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

pub fn playerVisualCardsIterator(context: *GameLogicContext, playerIndex: u8) CardsInHandIter
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
        const Self = @This();

        iter: TIter,
        context: TContext,

        pub fn next(self: *Self) ?WrappedIterOutputType
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
    response: PossibleResponse,
    context: *GameLogicContext,

    pub fn format(
        self: *const CardResponseWrapper,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        const r = self.response;
        const playerHand = &self.context.state.hands.items[self.context.state.defenderIndex()];

        const response: Card = playerHand.cards.items[r.handCardIndex];
        try response.print(writer, self.context.config);
        try writer.print(" -- ", .{});
        try response.printWithHighlightAt(writer, self.context.config, r.match.response);
    }
};

fn wrapResponse(a: PossibleResponse, b: *GameLogicContext) CardResponseWrapper
{
    return .{
        .response = a,
        .context = b,
    };
}

fn wrapResponseIter(context: *GameLogicContext, iter: PossibleResponsesIterator) 
    WrapIter(PossibleResponsesIterator, *GameLogicContext, wrapResponse)
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

pub fn getAndRealizeAttackerThrowOption(uiContext: *UiContext, context: *GameLogicContext, cout: anytype) !bool
{
    while (uiContext.attackersIterator.?.next()) |playerIndex|
    {
        const iter = getCardsAllowedForThrow(context, playerIndex);
        var printableIter = wrapCardIndexIterator(CardInHandContext
            {
                .config = context.config,
                .hand = &context.state.hands.items[playerIndex],
            }, iter);
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
                try throwIntoPlay(context, playerIndex, v.cardIndex);
                return true;
            }
        }
    }
    return false;
}
    
pub fn gameLogicLoop(context: *GameLogicContext, uiContext: *UiContext) !bool
{
    const cout = std.io.getStdOut().writer();

    if (try showGameOver(context, cout))
    {
        return true;
    }

    switch (gameStateHelper(context))
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
            try startPlayCard(context, selectedOption.cardIndex);
        },
        .Respond =>
        {
            {
                try cout.print("You have to beat ", .{});
                const attack = context.state.play.attackCard.?;
                try attack.print(cout, context.config);
                try cout.print("\n", .{});

            }
            const responsesIter = try getPossibleResponses(context);
            var wrappedIter = wrapResponseIter(context, responsesIter);
            const selectedResponse = try collectOptionsFromIteratorAndSelectOne(
                context.allocator,
                &wrappedIter,
                cout,
                "Take all");

            switch (selectedResponse)
            {
                .Empty => try takePlayIntoHand(context),
                .Value => |v| try respond(context, v.response),
            }
        },
        .ThrowIntoPlayOrEnd =>
        {
            if (!isDefenderAbleToRespond(context.state))
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
    var config = Config
    {
        .playerCount = 2,
        .handSize = 6,
        .maxValue = 6,
        .faceCount = 2,
    };
    config.init();

    var gameState = GameState
    {
    };

    var context = GameLogicContext
    {
        .allocator = std.heap.page_allocator,
        .state = &gameState,
        .randomState = std.rand.DefaultPrng.init(@bitCast(std.time.timestamp())),
        .config = &config,
    };
    try resetState(&context);

    var uiContext = UiContext
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
