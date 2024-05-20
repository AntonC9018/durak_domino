const std = @import("std");

pub fn FatPointer(VTable: type) type
{
    return struct
    {
        vtable: *const VTable,
        context: *anyopaque,
    };
}

pub const VTableImplConfig = struct
{
    VTable: type,
    unimplementedMethodsGetEmptyImplementation: bool = false,
    wrappedMemberName: ?[]const u8 = null,
    fallbackError: ?anyerror = null,
};

pub fn fatPointerFromImpl(context: anytype, comptime config: VTableImplConfig) FatPointer(config.VTable) 
{
    const storage = struct
    {
        const ContextT = @TypeOf(context.*);
        const vtable: config.VTable = vtable:
        {
            var result: config.VTable = undefined;
            const vtableInfo = @typeInfo(config.VTable);

            for (vtableInfo.Struct.fields) |field|
            {
                const funcPtrType = @TypeOf(@field(result, field.name));
                const funcType = FuncFromFuncPtr(funcPtrType);

                const wrapped = wrapped:
                {
                    const hasImpl = @hasDecl(ContextT, field.name);
                    if (hasImpl)
                    {
                        break :wrapped wrappedFunc(@field(ContextT, field.name));
                    }

                    if (config.wrappedMemberName) |wrappedName|
                    {
                        break :wrapped rerouteCallToMemberImpl(.{
                            .ImplType = ContextT,
                            .FuncPtrType = funcType,
                            .memberName = wrappedName,
                            .methodName = field.name,
                        });
                    }

                    if (config.unimplementedMethodsGetEmptyImplementation)
                    {
                        break :wrapped emptyImpl(funcType);
                    }
                };

                const wrappedAgain = wrappedAgain:
                {
                    if (config.fallbackError) |err|
                    {
                        const funcInfo = @typeInfo(funcType);
                        const returnType = funcInfo.Fn.return_type.?;
                        const returnTypeInfo = @typeInfo(returnType);

                        const TargetErrorSet = TargetErrorSet:
                        {
                            switch (returnTypeInfo)
                            {
                                .ErrorUnion => |errorUnion|
                                {
                                    break :TargetErrorSet errorUnion.error_set;
                                },
                                else => break :wrappedAgain wrapped,
                            }
                        };

                        break :wrappedAgain rewrapErrorSet(.{
                            .TargetErrorSet = TargetErrorSet,
                            .fallbackError = err,
                        }, wrapped);
                    }

                    break :wrappedAgain wrapped;
                };

                @field(result, field.name) = wrappedAgain;
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

fn FuncFromFuncPtr(FuncPtr: type) type
{
    const typeInfo = @typeInfo(FuncPtr);
    const ptrInfo = typeInfo.Pointer;
    return ptrInfo.child;
}

fn emptyImpl(comptime Func: type) WrappedFuncType(Func)
{
    const typeInfo = @typeInfo(Func);
    const funcInfo = typeInfo.Fn;
    switch (funcInfo.params.len)
    {
        1 =>
        {
            return &struct
            {
                pub fn f(context: *anyopaque) funcInfo.return_type.?
                {
                    _ = context;
                }
            }.f;
        },
        2 =>
        {
            return &struct
            {
                pub fn f(context: *anyopaque, params: funcInfo.params[0].type.?) funcInfo.return_type.?
                {
                    _ = context;
                    _ = params;
                }
            }.f;
        },
        else => std.debug.panic("Unimplemented"),
    }
}

const CallToMemberImplParams = struct
{
    ImplType: type,
    FuncType: type,
    memberName: []const u8,
    methodName: []const u8,
};

fn rerouteCallToMemberImpl(comptime params: CallToMemberImplParams) WrappedFuncType(params.FuncType)
{
    const typeInfo = @typeInfo(params.FuncType);
    const funcInfo = typeInfo.Fn;
    switch (funcInfo.params.len)
    {
        1 =>
        {
            return @ptrCast(&struct
            {
                pub fn f(context: *params.ImplType) funcInfo.return_type.?
                {
                    const mem = @field(context, params.memberName);
                    return @call(mem, params.methodName, .{ mem });
                }
            }.f);
        },
        2 =>
        {
            return @ptrCast(&struct
            {
                pub fn f(context: *params.ImplType, p: funcInfo.params[0].type.?) funcInfo.return_type.?
                {
                    const mem = @field(context, params.memberName);
                    return @call(mem, params.methodName, .{ mem, p });
                }
            }.f);
        },
        else => std.debug.panic("Unimplemented"),
    }
}

const RewrapErrorSetParams = struct
{
    TargetErrorSet: type,
    fallbackError: anyerror,

    fn availableErrors(comptime self: RewrapErrorSetParams) []const std.builtin.Type.Error
    {
        const i = @typeInfo(self.TargetErrorSet);
        return i.ErrorSet.?;
    }
};

fn FuncTypeWithError(Func: type, NewErrors: type) type
{
    var funcInfo = @typeInfo(Func);
    const ReturnType = funcInfo.Fn.return_type.?;
    
    const NewReturnType = newReturnType:
    {
        if (ReturnType == void)
        {
            break :newReturnType NewErrors!void;
        }
        const returnTypeInfo = @typeInfo(ReturnType);
        switch (returnTypeInfo)
        {
            .ErrorUnion => |eu|
            {
                var i = eu;
                i.error_set = NewErrors;
                break :newReturnType @Type(.{
                    .ErrorUnion = i,
                });
            },
            else => unreachable,
            // else => |t, k|
            // {
            // },
        }
    };
    funcInfo.Fn.return_type = NewReturnType;
    return @Type(funcInfo);
}

fn Helper(comptime params: RewrapErrorSetParams, FuncPtr: type) type
{
    const Func = FuncFromFuncPtr(FuncPtr);
    return FuncTypeWithError(Func, params.TargetErrorSet);
}

fn rewrapErrorSet(comptime params: RewrapErrorSetParams, func: anytype)
    *const Helper(params, @TypeOf(func))
{
    const funcType = Helper(params, @TypeOf(func));
    const funcInfo = @typeInfo(funcType).Fn;

    const oldFuncType = FuncFromFuncPtr(@TypeOf(func));
    const oldFuncTypeInfo = @typeInfo(oldFuncType);
    const oldReturnType = oldFuncTypeInfo.Fn.return_type.?;

    const availableErrors = params.availableErrors();

    const remapError = struct
    {
        fn f(val: oldReturnType) funcInfo.return_type.?
        {
            return val catch |err|
            {
                inline for (availableErrors) |e|
                {
                    const comptimeErr = @field(params.TargetErrorSet, e.name);
                    if (comptimeErr == err)
                    {
                        return comptimeErr;
                    }
                }
                return comptime @as(params.TargetErrorSet, @errorCast(params.fallbackError));
            };
        }
    }.f;

    switch (funcInfo.params.len)
    {
        1 =>
        {
            return @ptrCast(&struct
            {
                pub fn f(context: *anyopaque) funcInfo.return_type.?
                {
                    const result = func(context);
                    return remapError(result);
                }
            }.f);
        },
        2 =>
        {
            return @ptrCast(&struct
            {
                pub fn f(context: *anyopaque, p: funcInfo.params[1].type.?) funcInfo.return_type.?
                {
                    const result = func(context, p);
                    return remapError(result);
                }
            }.f);
        },
        else => std.debug.panic("Unimplemented"),
    }
}
