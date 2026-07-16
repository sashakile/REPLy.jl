@testset "describe middleware" begin
    @testset "describe returns required top-level fields" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.DescribeMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "describe", "id" => "d1"), ctx)

        @test msgs isa Vector
        @test length(msgs) == 1
        msg = only(msgs)
        @test msg["id"] == "d1"
        @test haskey(msg, "ops")
        @test haskey(msg, "versions")
        @test haskey(msg, "encodings-available")
        @test haskey(msg, "encoding-current")
        @test msg["status"] == ["done"]
    end

    @testset "describe ops catalog reflects middleware stack via build_handler" begin
        handler = REPLy.build_handler()  # uses default_middleware_stack()
        responses = handler(Dict("op" => "describe", "id" => "d2"))
        ops = only(responses)["ops"]

        # Default stack provides all built-in ops
        default_ops = ["eval", "interrupt", "ping", "stdin", "describe",
                       "ls-sessions", "close-session", "clone-session",
                       "load-file", "reload-file", "complete", "lookup", "ls-bindings"]
        for op in default_ops
            @test haskey(ops, op)
        end
    end

    @testset "each op in default stack has doc, requires, optional, and returns" begin
        handler = REPLy.build_handler()
        responses = handler(Dict("op" => "describe", "id" => "d3"))
        ops = only(responses)["ops"]

        for (name, op_desc) in ops
            @test op_desc isa AbstractDict
            @test haskey(op_desc, "doc")
            @test haskey(op_desc, "requires")
            @test haskey(op_desc, "optional")
            @test haskey(op_desc, "returns")
            @test op_desc["doc"] isa AbstractString
            @test op_desc["requires"] isa AbstractVector
            @test op_desc["optional"] isa AbstractVector
            @test op_desc["returns"] isa AbstractVector
        end
    end

    @testset "eval op descriptor has expected required and optional fields" begin
        handler = REPLy.build_handler()
        responses = handler(Dict("op" => "describe", "id" => "d4"))
        eval_desc = only(responses)["ops"]["eval"]

        @test "code" in eval_desc["requires"]
        @test "session" in eval_desc["optional"]
        @test "value" in eval_desc["returns"]
    end

    @testset "optional middleware ops appear when middleware added to stack" begin
        # Remove the default CompleteMiddleware, then add it back so there's
        # no duplicate — tests that describe picks up the added middleware.
        stack_base = filter(mw -> !(mw isa REPLy.CompleteMiddleware), REPLy.default_middleware_stack())
        stack = vcat(stack_base, [REPLy.CompleteMiddleware()])
        handler = REPLy.build_handler(; middleware=stack)
        responses = handler(Dict("op" => "describe", "id" => "d4b"))
        ops = only(responses)["ops"]
        @test haskey(ops, "complete")
    end

    @testset "versions contains julia and reply keys" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.DescribeMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "describe", "id" => "d5"), ctx)
        versions = only(msgs)["versions"]

        @test haskey(versions, "julia")
        @test haskey(versions, "reply")
        @test versions["julia"] == string(VERSION)
        @test versions["reply"] == REPLy.version_string()
    end

    @testset "encodings fields reflect json-only support" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.DescribeMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "describe", "id" => "d6"), ctx)
        msg = only(msgs)

        @test "json" in msg["encodings-available"]
        @test msg["encoding-current"] == "json"
    end

    @testset "non-describe ops are forwarded to the next middleware" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.DescribeMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "eval", "id" => "d7"), ctx)

        @test msgs isa Vector
        @test only(msgs)["err"] isa AbstractString
        @test occursin("eval", only(msgs)["err"])
    end
end
