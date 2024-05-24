const std = @import("std");

pub fn IterValueType(IterT: type) type
{
    const T = @TypeOf(b: {
        var t = @as(IterT, undefined);
        break :b t.next().?;
    });
    return T;
}

pub fn WrapIterFunc(
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

pub fn WrapIterMethod(TIter: type, TWrapper: type) type
{
    const IterOutputT = IterValueType(TIter);
    const WrappedIterOutputType = @TypeOf(
        @as(TWrapper, undefined).wrap(@as(IterOutputT, undefined)));

    return struct
    {
        const Self1 = @This();

        iter: TIter,
        context: TWrapper,

        pub fn next(self: *Self1) ?WrappedIterOutputType
        {
            if (self.iter.next()) |n|
            {
                return self.context.wrap(n);
            }
            return null;
        }
    };
}

pub fn wrapIterMethod(iter: anytype, wrapper: anytype) WrapIterMethod(@TypeOf(iter), @TypeOf(wrapper))
{
    return .{
        .iter = iter,
        .context = wrapper,
    };
}

fn EnumerateAllocReturn(Iter: type) type
{
    return std.ArrayListUnmanaged(IterValueType(Iter));
}

pub fn enumerateAlloc(iter: anytype, allocator: std.mem.Allocator) !EnumerateAllocReturn(@TypeOf(iter))
{
    var iter1 = iter;
    var list = EnumerateAllocReturn(@TypeOf(iter)){};
    errdefer list.deinit(allocator);
    while (iter1.next()) |next|
    {
        try list.append(allocator, next);
    }
    return list;
}
