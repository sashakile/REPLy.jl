@testset "error responders" begin
    @testset "eval runtime errors include structured exception data" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "runtime-1",
            "code" => "missing_name",
        ))

        assert_conformance(msgs, "runtime-1")
        @test count(msg -> "done" in get(msg, "status", String[]), msgs) == 1
        @test length(msgs) == 1

        msg = only(msgs)
        @test Set(msg["status"]) == Set(["done", "error"])
        @test occursin("UndefVarError", msg["err"])
        @test msg["ex"] isa AbstractDict
        @test msg["ex"]["type"] == "UndefVarError"
        @test !isempty(msg["ex"]["message"])
        @test msg["stacktrace"] isa Vector
        @test !isempty(msg["stacktrace"])
    end

    @testset "parse errors include parse exception metadata" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "parse-1",
            "code" => "function broken(",
        ))

        assert_conformance(msgs, "parse-1")
        @test count(msg -> "done" in get(msg, "status", String[]), msgs) == 1
        @test length(msgs) == 1

        msg = only(msgs)
        @test Set(msg["status"]) == Set(["done", "error"])
        @test occursin("ParseError", msg["err"])
        @test msg["ex"]["type"] == "Base.Meta.ParseError"
        @test !isempty(msg["ex"]["message"])
    end

    @testset "unknown operations use the unknown-op status flag" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "frobnicate",
            "id" => "unknown-1",
        ))

        assert_conformance(msgs, "unknown-1")
        @test count(msg -> "done" in get(msg, "status", String[]), msgs) == 1
        @test length(msgs) == 1

        msg = only(msgs)
        @test Set(msg["status"]) == Set(["done", "error", "unknown-op"])
        @test msg["err"] == "Unknown operation: frobnicate"
    end

    @testset "build_handler preserves validation errors for malformed requests" begin
        missing_op = only(REPLy.build_handler()(Dict("id" => "missing-op", "code" => "1+1")))
        missing_id = only(REPLy.build_handler()(Dict("op" => "eval", "code" => "1+1")))

        @test missing_op == Dict(
            "id" => "missing-op",
            "status" => ["done", "error"],
            "err" => "op is required",
        )
        @test missing_id == Dict(
            "id" => "",
            "status" => ["done", "error"],
            "err" => "id must not be empty",
        )
    end

    @testset "exceptions without .msg use showerror fallback" begin
        struct NoMsgError <: Exception end
        Base.showerror(io::IO, ::NoMsgError) = print(io, "no msg fallback")

        @test REPLy.exception_message(NoMsgError()) == "no msg fallback"
    end
end
