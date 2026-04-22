@testset "lookup middleware" begin
    function make_ctx()
        manager = REPLy.SessionManager()
        REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
    end

    @testset "lookup known symbol returns found=true with name, type, doc, methods" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LookupMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "lookup", "id" => "lu1", "symbol" => "println"), ctx)

        @test length(msgs) == 2
        result = msgs[1]
        @test result["id"] == "lu1"
        @test result["found"] == true
        @test result["name"] == "println"
        @test result["type"] isa AbstractString
        @test result["doc"] isa AbstractString
        @test result["methods"] isa AbstractVector
        @test msgs[2]["status"] == ["done"]
    end

    @testset "doc field is non-empty for a documented symbol" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LookupMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "lookup", "id" => "lu2", "symbol" => "println"), ctx)

        @test !isempty(msgs[1]["doc"])
    end

    @testset "methods field is non-empty for a callable" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LookupMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "lookup", "id" => "lu3", "symbol" => "println"), ctx)

        @test !isempty(msgs[1]["methods"])
        @test all(m isa AbstractString for m in msgs[1]["methods"])
    end

    @testset "lookup unknown symbol returns found=false" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LookupMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "lookup", "id" => "lu4", "symbol" => "__definitely_undefined_xyzzy__"), ctx)

        @test length(msgs) == 2
        @test msgs[1]["found"] == false
        @test msgs[2]["status"] == ["done"]
    end

    @testset "missing symbol field returns error" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LookupMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "lookup", "id" => "lu5"), ctx)

        @test "error" in only(msgs)["status"]
        @test occursin("string symbol field", only(msgs)["err"])
    end

    @testset "non-lookup ops are forwarded" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LookupMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "eval", "id" => "lu6"), ctx)

        @test "unknown-op" in only(msgs)["status"]
    end

    @testset "lookup in explicit module resolves symbol from that module" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LookupMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "lookup", "id" => "lu7", "symbol" => "join", "module" => "Base"), ctx)

        @test msgs[1]["found"] == true
        @test msgs[1]["name"] == "join"
    end
end
