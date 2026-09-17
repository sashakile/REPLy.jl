@testset "MiddlewareDescriptor and stack validation" begin
    # Concrete test middleware types
    struct ProvidesEval <: REPLy.AbstractMiddleware end
    struct ProvidesDescribe <: REPLy.AbstractMiddleware end
    struct RequiresEval <: REPLy.AbstractMiddleware end
    struct RequiresBoth <: REPLy.AbstractMiddleware end
    struct NoClaims <: REPLy.AbstractMiddleware end
    struct DuplicateEval <: REPLy.AbstractMiddleware end
    struct ExpectsEval <: REPLy.AbstractMiddleware end
    struct ExpectsBoth <: REPLy.AbstractMiddleware end

    REPLy.descriptor(::ProvidesEval) = REPLy.MiddlewareDescriptor(
        provides=Set(["eval"]),
        requires=Set{String}(),
        expects=Set{String}(),
    )
    REPLy.descriptor(::ProvidesDescribe) = REPLy.MiddlewareDescriptor(
        provides=Set(["describe"]),
        requires=Set{String}(),
        expects=Set{String}(),
    )
    REPLy.descriptor(::RequiresEval) = REPLy.MiddlewareDescriptor(
        provides=Set{String}(),
        requires=Set(["eval"]),
        expects=Set{String}(),
    )
    REPLy.descriptor(::RequiresBoth) = REPLy.MiddlewareDescriptor(
        provides=Set{String}(),
        requires=Set(["eval", "describe"]),
        expects=Set{String}(),
    )
    REPLy.descriptor(::DuplicateEval) = REPLy.MiddlewareDescriptor(
        provides=Set(["eval"]),
        requires=Set{String}(),
        expects=Set{String}(),
    )
    REPLy.descriptor(::ExpectsEval) = REPLy.MiddlewareDescriptor(
        provides=Set{String}(),
        requires=Set{String}(),
        expects=Set(["eval"]),
    )
    REPLy.descriptor(::ExpectsBoth) = REPLy.MiddlewareDescriptor(
        provides=Set{String}(),
        requires=Set{String}(),
        expects=Set(["eval", "describe"]),
    )

    @testset "MiddlewareDescriptor keyword construction" begin
        desc = REPLy.MiddlewareDescriptor(
            provides=Set(["eval"]),
            requires=Set(["session"]),
            expects=Set(["describe"]),
        )
        @test "eval" in desc.provides
        @test "session" in desc.requires
        @test length(desc.expects) == 1
    end

    @testset "default descriptor has no claims" begin
        desc = REPLy.descriptor(NoClaims())
        @test isempty(desc.provides)
        @test isempty(desc.requires)
        @test isempty(desc.expects)
    end

    @testset "validate_stack: valid stack with no claims returns no errors" begin
        stack = REPLy.AbstractMiddleware[NoClaims(), NoClaims()]
        @test isempty(REPLy.validate_stack(stack))
    end

    @testset "validate_stack: duplicate provides is an error" begin
        stack = REPLy.AbstractMiddleware[ProvidesEval(), DuplicateEval()]
        errors = REPLy.validate_stack(stack)
        @test length(errors) == 1
        @test occursin("eval", errors[1])
    end

    @testset "validate_stack: satisfied requires returns no errors" begin
        stack = REPLy.AbstractMiddleware[ProvidesEval(), RequiresEval()]
        @test isempty(REPLy.validate_stack(stack))
    end

    @testset "validate_stack: missing requires is an error" begin
        stack = REPLy.AbstractMiddleware[RequiresEval()]
        errors = REPLy.validate_stack(stack)
        @test length(errors) == 1
        @test occursin("eval", errors[1])
    end

    @testset "validate_stack: requires must be satisfied by earlier middleware (not later)" begin
        # RequiresEval before ProvidesEval — not satisfied at the point of check
        stack = REPLy.AbstractMiddleware[RequiresEval(), ProvidesEval()]
        errors = REPLy.validate_stack(stack)
        @test length(errors) == 1
        @test occursin("eval", errors[1])
    end

    @testset "validate_stack: multiple missing requires are each reported" begin
        stack = REPLy.AbstractMiddleware[RequiresBoth()]
        errors = REPLy.validate_stack(stack)
        @test length(errors) == 2
        @test any(e -> occursin("eval", e), errors)
        @test any(e -> occursin("describe", e), errors)
    end

    @testset "validate_stack: aggregates duplicate and missing errors together" begin
        # DuplicateEval duplicates ProvidesEval; RequiresBoth needs eval+describe (describe missing)
        stack = REPLy.AbstractMiddleware[ProvidesEval(), DuplicateEval(), RequiresBoth()]
        errors = REPLy.validate_stack(stack)
        @test length(errors) >= 2  # duplicate eval + missing describe (eval is provided)
        @test any(e -> occursin("duplicate", lowercase(e)) || occursin("eval", e), errors)
    end

    @testset "validate_stack: empty stack returns no errors" begin
        @test isempty(REPLy.validate_stack(REPLy.AbstractMiddleware[]))
    end

    @testset "validate_stack: expects satisfied by a later middleware returns no errors" begin
        stack = REPLy.AbstractMiddleware[ExpectsEval(), ProvidesEval()]
        @test isempty(REPLy.validate_stack(stack))
    end

    @testset "validate_stack: violated expects is an error naming the op" begin
        stack = REPLy.AbstractMiddleware[ExpectsEval()]
        errors = REPLy.validate_stack(stack)
        @test length(errors) == 1
        @test occursin("eval", errors[1])
    end

    @testset "validate_stack: expects is forward-looking — satisfied only by an earlier middleware is a violation" begin
        stack = REPLy.AbstractMiddleware[ProvidesEval(), ExpectsEval()]
        errors = REPLy.validate_stack(stack)
        @test length(errors) == 1
        @test occursin("eval", errors[1])
    end

    @testset "validate_stack: multiple violated expects are each reported" begin
        stack = REPLy.AbstractMiddleware[ExpectsBoth()]
        errors = REPLy.validate_stack(stack)
        @test length(errors) == 2
        @test any(e -> occursin("eval", e), errors)
        @test any(e -> occursin("describe", e), errors)
    end

    @testset "validate_stack: aggregates expects, requires, and duplicate errors together" begin
        stack = REPLy.AbstractMiddleware[ProvidesEval(), DuplicateEval(), RequiresBoth(), ExpectsBoth()]
        errors = REPLy.validate_stack(stack)
        # duplicate eval + missing describe (requires) + violated expects for eval and describe
        @test length(errors) == 4
    end

    @testset "validate_stack: expects_enforcement=:warn downgrades violations to warnings" begin
        stack = REPLy.AbstractMiddleware[ExpectsEval()]
        @test isempty(REPLy.validate_stack(stack; expects_enforcement=:warn))
        @test_throws ArgumentError("unsupported expects_enforcement mode: :loud") (
            REPLy.validate_stack(stack; expects_enforcement=:loud))
    end

    @testset "build_handler throws on violated expects by default" begin
        @test_throws ArgumentError REPLy.build_handler(
            middleware=REPLy.AbstractMiddleware[ExpectsEval()])
    end

    @testset "build_handler honors expects_enforcement=:warn" begin
        handler = REPLy.build_handler(
            middleware=REPLy.AbstractMiddleware[ExpectsEval(), ProvidesEval()],
            expects_enforcement=:warn)
        @test handler isa Function
    end
end

@testset "Built-in middleware descriptors" begin
    @testset "SessionMiddleware provides session capability" begin
        desc = REPLy.descriptor(REPLy.SessionMiddleware())
        @test "session" in desc.provides
        @test isempty(desc.requires)
    end

    @testset "SessionOpsMiddleware provides session ops and requires session" begin
        desc = REPLy.descriptor(REPLy.SessionOpsMiddleware())
        @test "ls-sessions"    in desc.provides
        @test "close-session"  in desc.provides
        @test "clone-session"  in desc.provides
        # Canonical OpenSpec names
        @test "close"          in desc.provides
        @test "clone"          in desc.provides
        @test "session"        in desc.requires
        @test "unknown-op"     in desc.expects  # must appear before UnknownOpMiddleware
    end

    @testset "DescribeMiddleware provides describe" begin
        desc = REPLy.descriptor(REPLy.DescribeMiddleware())
        @test "describe" in desc.provides
        @test isempty(desc.requires)
    end

    @testset "InterruptMiddleware provides interrupt and requires session" begin
        desc = REPLy.descriptor(REPLy.InterruptMiddleware())
        @test "interrupt" in desc.provides
        @test "session"   in desc.requires
    end

    @testset "StdinMiddleware provides stdin and requires session" begin
        desc = REPLy.descriptor(REPLy.StdinMiddleware())
        @test "stdin"   in desc.provides
        @test "session" in desc.requires
    end

    @testset "EvalMiddleware provides eval and requires session" begin
        desc = REPLy.descriptor(REPLy.EvalMiddleware())
        @test "eval"    in desc.provides
        @test "session" in desc.requires
    end

    @testset "UnknownOpMiddleware provides unknown-op" begin
        desc = REPLy.descriptor(REPLy.UnknownOpMiddleware())
        @test "unknown-op" in desc.provides
        @test isempty(desc.requires)
    end

    @testset "default_middleware_stack passes validate_stack" begin
        stack = REPLy.default_middleware_stack()
        errors = REPLy.validate_stack(stack)
        @test isempty(errors)
    end

    @testset "default_middleware_stack has no duplicate provides" begin
        stack = REPLy.default_middleware_stack()
        all_provides = [op for mw in stack for op in REPLy.descriptor(mw).provides]
        @test length(all_provides) == length(unique(all_provides))
    end

    @testset "MiddlewareDescriptor op_info field is empty by default" begin
        desc = REPLy.MiddlewareDescriptor(provides=Set(["eval"]), requires=Set(["session"]), expects=Set(["eval"]))
        @test isempty(desc.op_info)
    end

    @testset "DescribeMiddleware descriptor has describe op_info" begin
        desc = REPLy.descriptor(REPLy.DescribeMiddleware())
        @test haskey(desc.op_info, "describe")
        @test haskey(desc.op_info["describe"], "doc")
    end

    @testset "EvalMiddleware descriptor has eval op_info" begin
        desc = REPLy.descriptor(REPLy.EvalMiddleware())
        @test haskey(desc.op_info, "eval")
        @test "code" in desc.op_info["eval"]["requires"]
    end

    @testset "CompleteMiddleware provides complete" begin
        desc = REPLy.descriptor(REPLy.CompleteMiddleware())
        @test "complete" in desc.provides
        @test haskey(desc.op_info, "complete")
    end

    @testset "LookupMiddleware provides lookup" begin
        desc = REPLy.descriptor(REPLy.LookupMiddleware())
        @test "lookup" in desc.provides
        @test haskey(desc.op_info, "lookup")
    end

    @testset "LoadFileMiddleware provides load-file" begin
        desc = REPLy.descriptor(REPLy.LoadFileMiddleware())
        @test "load-file" in desc.provides
        @test haskey(desc.op_info, "load-file")
    end

    @testset "ReloadFileMiddleware expects load-file later in the stack" begin
        desc = REPLy.descriptor(REPLy.ReloadFileMiddleware())
        @test "load-file" in desc.expects
    end

    @testset "backward positional constraints live in requires, not expects" begin
        # "must appear after SessionMiddleware" is enforced via requires = ["session"];
        # expects is reserved for forward-looking constraints.
        for mw in (REPLy.EvalMiddleware(), REPLy.StdinMiddleware(),
                   REPLy.InterruptMiddleware(), REPLy.LsBindingsMiddleware())
            @test isempty(REPLy.descriptor(mw).expects)
        end
    end
end
