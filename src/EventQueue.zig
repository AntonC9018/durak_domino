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
    std.debug.print("Adding the event {any}\n", .{ ev });
    try self.events.append(ev);

    std.debug.print("new length: {}\n", .{ self.events.items.len });
}

pub fn debugPrint(self: *const Self) void
{
    std.debug.print("{any}\n", .{ self.events.items });
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
