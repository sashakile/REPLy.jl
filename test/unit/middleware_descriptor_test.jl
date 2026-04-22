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
