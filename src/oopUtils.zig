const std = @import("std");

pub fn FatPointer(VTable: type) type
{
    return struct
    {
        vtable: VTable,
        context: *anyopaque,
    };
}

pub fn fatPointerFromImpl(context: anytype, VTable: type) FatPointer(VTable) 
{
    const storage = struct
    {
        const ContextT = @TypeOf(context.*);
        const vtable: VTable = vtable:
        {
            var result: VTable = undefined;
            const vtableInfo = @typeInfo(VTable);

            for (vtableInfo.Struct.fields) |field|
            {
                const wrapped = wrappedFunc(@field(ContextT, field.name));
                // const fieldTypeInfo = @typeInfo(field.type);
                // const returnType = fieldTypeInfo.Fn.returnType;
                @field(result, field.name) = wrapped;
            }

            break :vtable result;
        };

    };

    return .{
        .context = @ptrCast(context),
        .vtable = &storage.vtable,
    };
}

pub fn Delegate(Func: type) type
{
    return struct
    {
        func: Func,
        context: *anyopaque,
    };
}

pub fn delegateFromImpl(context: anytype, Func: type) Delegate(Func)
{
    const storage = struct
    {
        const ContextT = @TypeOf(context.*);
        const func = wrappedFunc(ContextT.execute);
    };
    return .{
        .context = @ptrCast(context),
        .func = storage.func,
    };
}

fn WrappedFuncType(FuncType: type) type
{
    var info = @typeInfo(FuncType);
    const params = info.Fn.params;

    std.debug.assert(@typeInfo(params[0].type.?) == .Pointer);

    var newParams = params[0 .. params.len].*;
    newParams[0] = .{
        .is_generic = false,
        .is_noalias = false,
        .type = *anyopaque,
    };

    info.Fn.params = &newParams;
    const resultFuncType = @Type(info);

    return *const resultFuncType;
}

fn wrappedFunc(comptime func: anytype) WrappedFuncType(@TypeOf(func))
{
    return @ptrCast(&func);
}

