const std = @import("std");

const maxSideCount = 8;

pub const Card = struct
{
    values: CardSide[maxSideCount],

    pub fn getValuesSlice(card: anytype, conf: Config)
        switch (@TypeOf(card))
        {
            *Card => []CardSide,
            *const Card => []const CardSide,
            else => unreachable
        }
    {
        return card.values[0 .. conf.faceCount];
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
    deckSize: u32,
    playerCount: u8,

    pub fn numValuesForFace(self: *Config) u8
    {
        return self.maxValue + 1;
    }

    pub fn init(self: *Config) void
    {
        const numSelectionForEachFace = self.maxValue + 1;
        const numFaces = self.faceCount;
        const numCombinations = std.math.powi(numSelectionForEachFace, numFaces);
        // Do not count duplicates.
        return numCombinations / 2;
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
    nextAllowedValue: ?u8 = null,

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

pub const EndResult = union(enum)
{
    Lose: u8,
    Incomplete: void,
    Tie: void,
};

pub fn getEndResult(game: *const GameState) EndResult
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
    var next = game.attackerIndex +% 1;
    while (true)
    {
        if (game.hands.items[next].cards.items.len != 0)
        {
            return @intCast(next);
        }
        if (game.attackerIndex == next)
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
    handCardIndex: u8,
    match: ValueIndexMatchPair,
};

pub fn allOthersLarger(p: struct
    {
        target: Card,
        play: Card,
        match: ValueIndexMatchPair,
        config: *Config,
    }) bool
{
    std.debug.assert(p.config.faceCount == 2);

    const otherPlayIndex = (p.match.attack +% 1) % 2;
    const otherPlayValue = p.play.values[otherPlayIndex];

    const otherTargetIndex = (p.match.response +% 1) % 2;
    const otherTargetValue = p.target.values[otherTargetIndex];

    if (otherPlayValue < otherTargetValue)
    {
        return true;
    }
    return false;
}

pub const MatchesIteratorState = struct
{
    playIndex: u8 = 0,
    targetIndex: u8 = 0,
    matchingWildcards: bool = false,
};

pub const MatchesIterator = struct
{
    state: MatchesIteratorState,
    playCard: Card,
    targetCard: Card,
    config: *const Config,

    pub fn advance(self: *MatchesIterator) void
    {
        const s = &self.state;
        if (s.matchingWildcards)
        {
            s.targetIndex += 1;
            return;
        }

        if (s.targetIndex < self.config.faceCount - 1)
        {
            s.targetIndex += 1;
            return;
        }

        s.targetIndex = 0;

        if (s.playIndex < self.config.faceCount - 1)
        {
            s.playIndex += 1;
            return;
        }

        s.matchingWildcards = true;
        s.playIndex = 0;
        s.targetIndex = 0;
    }

    pub fn isDone(self: *const MatchesIterator) bool
    {
        const s = &self.state;
        return s.targetIndex == self.config.maxSideCount;
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

            const targetValue = self.targetCard.values[state.targetIndex];
            if (state.matchingWildcards)
            {
                if (self.valuePlay != self.config.maxValue)
                {
                    continue;
                }

                const largestIndex = largestIndex:
                {
                    var maxIndex = if (state.targetIndex == 0) 1 else 0;
                    for (maxIndex + 1 .., self.targetCard.getValuesSlice(self.config)) |i, b|
                    {
                        if (i == state.targetIndex)
                        {
                            continue;
                        }
                        const a = self.playCard.values[maxIndex];
                        if (b > a)
                        {
                            maxIndex = i;
                        }
                    }
                    break :largestIndex maxIndex;
                };

                return .{
                    .target = state.targetIndex,
                    .play = largestIndex,
                };
            }
            else
            {
                const playValue = self.playCard.values[state.playIndex];

                if (playValue != targetValue)
                {
                    continue;
                }

                const potentialResult = .{
                    .target = state.targetIndex,
                    .play = self.playCard,
                };

                if (allOthersLarger(.{
                        .target = self.targetCard,
                        .play = self.playCard,
                        .match = potentialResult,
                        .confg = self.config
                    }))
                {
                    continue;
                }

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
        self.matchesIterator = .{
            .playCard = self.cardInPlay,
            .targetCard = self.currentHand.cards.items[self.handCardIndex],
            .config = self.config,
            .state = .{},
        };
    }

    pub fn next(self: *PossibleResponsesIterator) ?PossibleResponse
    {
        while (!self.isDone())
        {
            if (self.matchesIterator.next()) |n|
            {
                return .{
                    .handCardIndex = self.handCardIndex,
                    .match = n,
                };
            }

            self.resetMatchesIterator();
            self.handCardIndex += 1;
        }
        return null;
    }
};

pub fn getPossibleResponses(context: *const GameLogicContext) !PossibleResponsesIterator
{
    const play = &(context.state.play orelse return error.NoPlay);
    const cardInPlay = &(play.incompletePair orelse return error.NoCardInPlay);
    const currentHand = &context.state.hands.items[context.state.attackerIndex];
    var iter = PossibleResponsesIterator
    {
        .cardInPlay = cardInPlay,
        .currentHand = currentHand,
        .config = context.config,
    };
    iter.init();
    return iter;
}

pub const AllCardIterator = struct
{
    current: Card,
    indexCount: u8,
    maxValue: u8,
    done: bool = false,

    pub fn next(self: *AllCardIterator) ?Card
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
        result.values[faceIndex] = currentRemaining % config.numValuesForFace();
        currentRemaining /= config.numValuesForFace();
    }
    return result;
}

pub fn isWildcard(side: CardSide) bool
{
}

pub fn resetState(context: *const GameLogicContext) !void
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
        for (0 .., drawPile) |i, *card|
        {
            card.* = convertIndexToCard(i, context.config);
        }

        // Shuffle deck
        for (drawPile) |*card|
        {
            const i = context.randomState.random().int(usize) % drawPile.len;

            const t = card.*;
            card.* = drawPile[i];
            drawPile[i] = t;
        }
    }

    context.state.discardPile.items.len = 0;
    context.state.attackerIndex = 0;
    context.state.play = null;

    const hands = &context.state.hands.items;
    {
        const oldPlayerCount = hands.len;
        if (context.config.playerCount < oldPlayerCount)
        {
            for (hands.*[context.config.playerCount .. oldPlayerCount]) |*hand|
            {
                hand.cards.deinit(context.allocator);
            }
        }

        hands.len = context.config.playerCount;

        if (oldPlayerCount > context.config.playerCount)
        {
            for (hands.*[oldPlayerCount .. context.config.playerCount]) |*hand|
            {
                hand.* = .{};
            }
        }
    }

    // Deal cards
    for (hands.*) |*hand|
    {
        hand.cards.ensureTotalCapacity(context.config.handSize);
        hand.cards.items.len = context.config.handSize;
        const drawPile = &context.state.drawPile.items;
        for (hand.cards, drawPile[(drawPile.len - context.config.handSize) ..]) |*card, draw|
        {
            card.* = draw;
        }
        drawPile.len -= context.config.handSize;
    }
}

pub fn removeCardFromHand(hand: *Hand, cardIndex: u8) !Card
{
    const cards = &hand.cards;
    if (cardIndex >= cards.items.len - 1)
    {
        return error.InvalidCardIndex;
    }

    const card = cards.orderedRemove(cardIndex);
    return card;
}

pub fn startPlayCard(context: *GameLogicContext, cardIndex: u8) !void
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

    const responseCard = try removeCardFromHand(response.handCardIndex);

    play.attackCard = null;

    const allowedValue = responseCard.values[response.match.response];
    std.debug.assert(allowedValue == attackCard.values[response.match.attack]);

    play.nextAllowedValue = allowedValue;
    try play.completePairs.append(context.allocator, .{
        .attack = attackCard,
        .response = responseCard,
    });
}

pub fn isDefenderAbleToRespond(state: *const GameState) bool
{
    const defenderHand = state.hands.items[state.defenderIndex()];
    return (defenderHand.cards.items.len == 0);
}

pub fn throwIntoPlay(context: *GameLogicContext, playerIndex: u8, cardIndex: u8) !void
{
    if (!isDefenderAbleToRespond(context.state))
    {
        return error.DefenderWontBeAbleToRespond;
    }

    const hand = &context.state.hands[playerIndex].items;
    const card = try removeCardFromHand(hand, cardIndex);
    blk: {
        const nextAllowedValue = context.state.play.nextAllowedValue 
            orelse return error.NextAllowedValueUninitialized;
        for (card.getValuesSlice()) |side|
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
        orelse error.GameOver;

    context.state.turnIndices = .{ 
        .attacker = newAttacker,
        .defender = newDefender,
    };
}

pub fn movePlayPairsInto(
    allocator: std.mem.Allocator,
    play: *Play,
    into: std.ArrayListUnmanaged(Card)) !void
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
        const hand = context.state.hands.items[currentIndex];
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

    const hand = context.state.hands.items[context.state.defenderIndex()];
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
    resetState(gameState);

    const context = GameLogicContext
    {
        .allocator = std.heap.page_allocator,
        .state = &gameState,
        .randomState = std.rand.DefaultPrng.init(@bitCast(std.time.timestamp())),
        .config = &config,
    };

    const cout = std.io.getStdOut().writer();

    while (true)
    { 
        const endState = getEndResult(context);
        switch (endState)
        {
            .Incomplete => {},
            .Lose => |i|
            {
                cout.print("Player {} loses.\n", .{ i });
                return 0;
            },
            .Tie =>
            {
                cout.print("Tie.\n", .{});
                return 0;
            },
        }

        switch (gameStateHelper(context))
        {
            .Play =>
            {
                // select a card to play...
                const selectedCardIndex: u8 = 0;
                try startPlayCard(context, selectedCardIndex);
            },
            .Respond =>
            {
                const possibleResponses = try getPossibleResponses(context);
                if (possibleResponses.next()) |firstOption|
                {
                    try respond(context, firstOption);
                }
                else
                {
                    try takePlayIntoHand(context);
                }
            },
            .ThrowIntoPlayOrEnd =>
            {
                // player index that's going to throw.
                const playerToThrow = context.state.attackerIndex();
                // get options (iterator)
                // select option
                if (context.state.hands.items[playerToThrow].cards.items.len > 0
                    and isDefenderAbleToRespond(context.state))
                {
                    const selectedCardIndex = 0;
                    // throw or go to next player
                    try throwIntoPlay(context, playerToThrow, selectedCardIndex);
                }
                // end at the end.
                else
                {
                    try endPlay(context);
                    try redraw(context);
                    try moveTurnToNextPlayer(context);
                }
            },
        }
    }
}
