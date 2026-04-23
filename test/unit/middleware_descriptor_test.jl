@testset "MiddlewareDescriptor and stack validation" begin
    # Concrete test middleware types
    struct ProvidesEval <: REPLy.AbstractMiddleware end
    struct ProvidesDescribe <: REPLy.AbstractMiddleware end
    struct RequiresEval <: REPLy.AbstractMiddleware end
    struct RequiresBoth <: REPLy.AbstractMiddleware end
    struct NoClaims <: REPLy.AbstractMiddleware end
    struct DuplicateEval <: REPLy.AbstractMiddleware end

    REPLy.descriptor(::ProvidesEval) = REPLy.MiddlewareDescriptor(
        provides=Set(["eval"]),
        requires=Set{String}(),
        expects=String[],
    )
    REPLy.descriptor(::ProvidesDescribe) = REPLy.MiddlewareDescriptor(
        provides=Set(["describe"]),
        requires=Set{String}(),
        expects=String[],
    )
    REPLy.descriptor(::RequiresEval) = REPLy.MiddlewareDescriptor(
        provides=Set{String}(),
        requires=Set(["eval"]),
        expects=String[],
    )
    REPLy.descriptor(::RequiresBoth) = REPLy.MiddlewareDescriptor(
        provides=Set{String}(),
        requires=Set(["eval", "describe"]),
        expects=String[],
    )
    REPLy.descriptor(::DuplicateEval) = REPLy.MiddlewareDescriptor(
        provides=Set(["eval"]),
        requires=Set{String}(),
        expects=String[],
    )

    @testset "MiddlewareDescriptor keyword construction" begin
        desc = REPLy.MiddlewareDescriptor(
            provides=Set(["eval"]),
            requires=Set(["session"]),
            expects=["session must precede eval"],
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

    @testset "validate_stack: expects strings are accessible but not error-checked" begin
        desc = REPLy.MiddlewareDescriptor(
            provides=Set{String}(),
            requires=Set{String}(),
            expects=["some ordering constraint"],
        )
        @test length(desc.expects) == 1
        @test desc.expects[1] == "some ordering constraint"
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
        desc = REPLy.MiddlewareDescriptor(provides=Set(["eval"]), requires=Set(["session"]), expects=["session must precede eval"])
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
end
