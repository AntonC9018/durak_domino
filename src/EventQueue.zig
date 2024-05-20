const std = @import("std");
const core = @import("core.zig");

events: std.ArrayList(Event),

const Self = @This();

pub fn create(allocator: std.mem.Allocator) Self
{
    return .{
        .events = std.ArrayList(Event).init(allocator),
    };
}

pub fn addEvent(self: *Self, ev: Event) std.mem.Allocator.Error!void
{
    try self.events.append(ev);
}

pub const ResponseEvent = union(enum)
{
    Defense: core.Defense,
    Take: void,
};

pub const ThrowEvent = union(enum)
{
    Throw: core.ThrowAttack,
    Skip: void,
};

pub const InitialAttackEvent = core.InitialAttack;

pub const Event = union(enum)
{
    Response: ResponseEvent,
    Play: InitialAttackEvent,
    Throw: ThrowEvent,
};
