@testset "integration: tracer bullet pipeline" begin
    @testset "success path returns buffered stdout before value and done" begin
        request = Dict(
            "op" => "eval",
            "id" => "integration-1",
            "code" => "print(\"hello\"); println(\" world\"); 1 + 1",
        )

        handler = REPLy.build_handler()
        msgs = handler(request)

        assert_conformance(msgs, request["id"])
        out_msgs = filter(msg -> haskey(msg, "out"), msgs)
        @test join(getindex.(out_msgs, "out")) == "hello world\n"
        @test any(get(msg, "value", nothing) == "2" for msg in msgs)
    end

    @testset "unknown op returns unknown-op error" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "frobnicate",
            "id" => "integration-unknown",
        ))

        assert_conformance(msgs, "integration-unknown")
        @test length(msgs) == 1
        @test Set(msgs[1]["status"]) == Set(["done", "error", "unknown-op"])
        @test msgs[1]["err"] == "Unknown operation: frobnicate"
    end

    @testset "parse errors return structured error response" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "integration-parse",
            "code" => "function broken(",
        ))

        assert_conformance(msgs, "integration-parse")
        @test length(msgs) == 1
        @test Set(msgs[1]["status"]) == Set(["done", "error"])
        @test occursin("ParseError", msgs[1]["err"])
        @test msgs[1]["ex"]["type"] == "Base.Meta.ParseError"
    end

    @testset "eval errors return structured error response" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "integration-eval-error",
            "code" => "missing_name",
        ))

        assert_conformance(msgs, "integration-eval-error")
        @test length(msgs) == 1
        @test Set(msgs[1]["status"]) == Set(["done", "error"])
        @test occursin("UndefVarError", msgs[1]["err"])
        @test msgs[1]["ex"]["type"] == "UndefVarError"
    end

    @testset "describe returns ops, versions, and encoding fields via default stack" begin
        msgs = REPLy.build_handler()(Dict("op" => "describe", "id" => "integration-describe"))

        @test length(msgs) == 1
        msg = only(msgs)
        @test msg["id"] == "integration-describe"
        @test msg["status"] == ["done"]
        @test haskey(msg, "ops")
        @test haskey(msg["ops"], "eval")
        @test haskey(msg["ops"], "describe")
        @test haskey(msg, "versions")
        @test haskey(msg["versions"], "julia")
        @test haskey(msg["versions"], "reply")
        @test "json" in msg["encodings-available"]
        @test msg["encoding-current"] == "json"
    end

    @testset "ephemeral eval flow does not leak sessions" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        @test REPLy.session_count(manager) == 0
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "integration-cleanup",
            "code" => "println(\"hi\"); 40 + 2",
        ))
        @test REPLy.session_count(manager) == 0

        assert_conformance(msgs, "integration-cleanup")
        @test any(get(msg, "value", nothing) == "42" for msg in msgs)
    end

    @testset "large buffered stdout completes and preserves terminal value" begin
        handler = REPLy.build_handler()
        msgs = handler(Dict(
            "op" => "eval",
            "id" => "integration-large-output",
            "code" => "print(repeat(\"b\", 200000)); 9",
        ))

        assert_conformance(msgs, "integration-large-output")
        out_msgs = filter(msg -> haskey(msg, "out"), msgs)
        @test sum(ncodeunits(msg["out"]) for msg in out_msgs) == 200000
        @test only(filter(msg -> haskey(msg, "value"), msgs))["value"] == "9"
    end
end
