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

    @testset "describe ops catalog includes all required operations" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.DescribeMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "describe", "id" => "d2"), ctx)
        ops = only(msgs)["ops"]

        required_ops = ["eval", "clone-session", "close-session", "complete", "lookup",
                        "interrupt", "ls-sessions", "stdin", "load-file", "describe"]
        for op in required_ops
            @test haskey(ops, op)
        end
    end

    @testset "each op descriptor has doc, requires, optional, and returns" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.DescribeMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "describe", "id" => "d3"), ctx)
        ops = only(msgs)["ops"]

        for (name, descriptor) in ops
            @test descriptor isa AbstractDict
            @test haskey(descriptor, "doc")
            @test haskey(descriptor, "requires")
            @test haskey(descriptor, "optional")
            @test haskey(descriptor, "returns")
            @test descriptor["doc"] isa AbstractString
            @test descriptor["requires"] isa AbstractVector
            @test descriptor["optional"] isa AbstractVector
            @test descriptor["returns"] isa AbstractVector
        end
    end

    @testset "eval op descriptor has expected required and optional fields" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = REPLy.AbstractMiddleware[REPLy.DescribeMiddleware(), REPLy.UnknownOpMiddleware()]

        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "describe", "id" => "d4"), ctx)
        eval_desc = only(msgs)["ops"]["eval"]

        @test "code" in eval_desc["requires"]
        @test "session" in eval_desc["optional"]
        @test "value" in eval_desc["returns"]
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
        @test only(msgs)["err"] isa AbstractString  # UnknownOpMiddleware returns error
        @test occursin("eval", only(msgs)["err"])
    end
end
