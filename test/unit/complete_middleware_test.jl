@testset "complete middleware" begin
    function make_ctx()
        manager = REPLy.SessionManager()
        REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
    end

    @testset "completions returns candidates and done for valid code and pos" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.CompleteMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "complete", "id" => "c1", "code" => "pri", "pos" => 3), ctx)

        @test length(msgs) == 2
        comp_msg = msgs[1]
        done_msg = msgs[2]
        @test haskey(comp_msg, "completions")
        @test comp_msg["completions"] isa AbstractVector
        @test done_msg["status"] == ["done"]
        # "println" should be in completions for "pri"
        texts = [c["text"] for c in comp_msg["completions"]]
        @test any(startswith(t, "pri") || t == "println" || occursin("print", t) for t in texts)
    end

    @testset "each completion has text and type fields" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.CompleteMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "complete", "id" => "c2", "code" => "pri", "pos" => 3), ctx)

        comp_msg = msgs[1]
        @test !isempty(comp_msg["completions"])
        for c in comp_msg["completions"]
            @test haskey(c, "text")
            @test haskey(c, "type")
            @test c["text"] isa AbstractString
            @test c["type"] isa AbstractString
        end
    end

    @testset "negative pos returns empty completions (not an error)" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.CompleteMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "complete", "id" => "c3", "code" => "print", "pos" => -1), ctx)

        @test length(msgs) == 2
        @test msgs[1]["completions"] == []
        @test msgs[2]["status"] == ["done"]
    end

    @testset "pos beyond code length returns empty completions" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.CompleteMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "complete", "id" => "c4", "code" => "abc", "pos" => 100), ctx)

        @test msgs[1]["completions"] == []
        @test msgs[2]["status"] == ["done"]
    end

    @testset "missing code field returns error" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.CompleteMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "complete", "id" => "c5", "pos" => 3), ctx)

        @test "error" in only(msgs)["status"]
        @test occursin("string code field", only(msgs)["err"])
    end

    @testset "missing pos field returns error" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.CompleteMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "complete", "id" => "c6", "code" => "print"), ctx)

        @test "error" in only(msgs)["status"]
        @test occursin("integer pos field", only(msgs)["err"])
    end

    @testset "non-complete ops are forwarded" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.CompleteMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "eval", "id" => "c7"), ctx)

        @test "unknown-op" in only(msgs)["status"]
    end
end
