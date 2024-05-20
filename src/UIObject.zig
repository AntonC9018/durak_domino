obj: Object,

const core = @import("core.zig");
const std = @import("std");
const oopUtils = @import("oopUtils.zig");
const EventQueue = @import("EventQueue.zig");

pub const Object = oopUtils.FatPointer(VTable);
const Self = @This();

pub const fallbackError = error.UIError;
pub const ErrorSet = error{Error} || std.mem.Allocator.Error;

pub fn setOptions(self: Self, params: SetOptionsParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.setOptions;
    return f(c, params);
}

pub fn passTurn(self: Self, params: PassTurnParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.passTurn;
    return f(c, params);
}

pub fn play(self: Self, params: PlayParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.play;
    return f(c, params);
}

pub fn redraw(self: Self, params: RedrawParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.redraw;
    return f(c, params);
}

pub fn respond(self: Self, params: RespondParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.respond;
    return f(c, params);
}

pub fn throwIntoPlay(self: Self, params: ThrowIntoPlayParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.throwIntoPlay;
    return f(c, params);
}

pub fn endPlay(self: Self, params: EndPlayParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.endPlay;
    return f(c, params);
}

pub fn gameOver(self: Self, params: GameOverParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.gameOver;
    return f(c, params);
}

pub fn moveIntoDrawPile(self: Self, params: MoveIntoDrawPileParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.moveIntoDrawPile;
    return f(c, params);
}

pub fn resetPlay(self: Self, params: ResetPlayParameters) ErrorSet!void
{
    const c: *Context = @ptrCast(self.obj.context);
    const f = self.obj.vtable.resetPlay;
    return f(c, params);
}

const GameLogicContext = core.GameLogicContext;

pub const SetOptionsParameters = struct
{
    playOption: core.PlayOption,
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
    playerIndex: usize,
    response: core.Defense,
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
    controller: *EventQueue,
};

pub const Context = anyopaque;

pub const VTable = struct
{
    setOptions: Func(SetOptionsParameters),

    play: Func(PlayParameters),
    redraw: Func(RedrawParameters),
    respond: Func(RespondParameters),
    throwIntoPlay: Func(ThrowIntoPlayParameters),
    endPlay: Func(EndPlayParameters),

    passTurn: Func(PassTurnParameters),
    moveIntoDrawPile: Func(MoveIntoDrawPileParameters),

    gameOver: Func(GameOverParameters),
    resetPlay: Func(ResetPlayParameters),

    fn Func(Params: type) type
    {
        return *const fn(context: *Context, value: Params) ErrorSet!void;
    }
};

pub fn create(context: anytype) Self
{
    const result = oopUtils.fatPointerFromImpl(context, .{
        .VTable = VTable,
        .fallbackError = fallbackError,
    });
    return .{
        .obj = result,
    };
}
