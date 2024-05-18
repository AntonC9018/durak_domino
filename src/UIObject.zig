obj: Object,

const core = @import("core.zig");
const std = @import("std");
const oopUtils = @import("oopUtils.zig");

pub const Object = oopUtils.FatPointer(VTable);
const Self = @This();

pub fn setResponses(self: Self, params: SetResponsesParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.setResponses;
    return f(c, params);
}

pub fn passTurn(self: Self, params: PassTurnParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.passTurn;
    return f(c, params);
}

pub fn play(self: Self, params: PlayParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.play;
    return f(c, params);
}

pub fn redraw(self: Self, params: RedrawParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.redraw;
    return f(c, params);
}

pub fn respond(self: Self, params: RespondParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.respond;
    return f(c, params);
}

pub fn throwIntoPlay(self: Self, params: ThrowIntoPlayParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.throwIntoPlay;
    return f(c, params);
}

pub fn endPlay(self: Self, params: EndPlayParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.endPlay;
    return f(c, params);
}

pub fn gameOver(self: Self, params: GameOverParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.gameOver;
    return f(c, params);
}

pub fn moveIntoDrawPile(self: Self, params: MoveIntoDrawPileParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.moveIntoDrawPile;
    return f(c, params);
}

pub fn resetPlay(self: Self, params: ResetPlayParameters) bool
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.resetPlay;
    return f(c, params);
}

const GameLogicContext = core.GameLogicContext;

pub const SetResponsesParameters = struct
{
    iter: core.PossibleResponsesIterator,
};

pub const PassTurnParameters = struct
{
    players: core.CurrentPlayers,
};

pub const PlayParameters = struct
{
    playerIndex: usize,
    cardIndex: usize,
    card: core.Card,
};

pub const PlayerDraw = struct
{
    playerIndex: usize,
    addedCards: []const core.Card,
};

pub const RedrawParameters = struct
{
    // If moved for later use, the array should be reset to default.
    // The cards arrays use the same allocator as this.
    draws: *std.ArrayList(PlayerDraw),
};

pub const RespondParameters = struct
{
    response: core.PossibleResponse,
};

pub const ThrowIntoPlayParameters = struct
{
    playerIndex: usize,
    card: core.Card,
};

pub const EndPlayParameters = struct
{
};

pub const GameOverParameters = struct
{
    result: core.CompletionStatus,
};

pub const MoveIntoDrawPileParameters = struct
{
    cards: []const core.Card,
};

pub const ResetPlayParameters = struct
{
};

pub const SelectResponseParameters = struct
{
    callback: ControllerCallback(core.PossibleResponse),
};

pub const Context = anyopaque;

pub const VTable = struct
{
    setResponses: Func(SetResponsesParameters),
    passTurn: Func(PassTurnParameters),
    play: Func(PlayParameters),
    redraw: Func(RedrawParameters),
    respond: Func(RespondParameters),
    throwIntoPlay: Func(ThrowIntoPlayParameters),
    endPlay: Func(EndPlayParameters),
    gameOver: Func(GameOverParameters),
    moveIntoDrawPile: Func(MoveIntoDrawPileParameters),
    resetPlay: Func(ResetPlayParameters),

    fn Func(Params: type) type
    {
        return *const fn(context: *Context, value: Params) bool;
    }
};

pub fn ControllerCallback(Value: type) type
{
    const Func = VTable.Func(Value);
    return oopUtils.Delegate(Func);
}

pub fn create(context: anytype) Object
{
    return oopUtils.fatPointerFromImpl(context);
}
