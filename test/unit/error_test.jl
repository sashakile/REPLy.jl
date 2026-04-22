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

    @testset "exception_message falls back when showerror throws" begin
        struct BrokenShowerror <: Exception end
        Base.show(io::IO, ::BrokenShowerror) = error("broken show")

        msg = REPLy.exception_message(BrokenShowerror())
        @test msg == "<showerror failed: BrokenShowerror>"
    end

    @testset "fallback_render strips unstable module prefixes" begin
        m = Module()
        Core.eval(m, :(struct HiddenType end))
        value = getfield(m, :HiddenType)()

        @test REPLy.fallback_render("repr", value) == "<repr failed: HiddenType>"
    end

    @testset "fallback_render preserves useful parametric type detail" begin
        @test REPLy.fallback_render("repr", [1, 2]) == "<repr failed: Vector{Int64}>"
        @test REPLy.fallback_render("repr", Dict("a" => 1)) == "<repr failed: Dict{String, Int64}>"
    end

    @testset "truncate_output appends marker and respects byte limit" begin
        big = repeat("x", 1000)
        result = REPLy.truncate_output(big, 10)
        @test endswith(result, REPLy.OUTPUT_TRUNCATION_MARKER)
        @test ncodeunits(result) == 10 + ncodeunits(REPLy.OUTPUT_TRUNCATION_MARKER)
    end

    @testset "truncate_output returns string unchanged when at or under limit" begin
        s = "hello"
        @test REPLy.truncate_output(s, 5) === s
        @test REPLy.truncate_output(s, 100) === s
    end

    @testset "truncate_output handles UTF-8 multi-byte characters safely" begin
        s = "héllo"  # é is 2 bytes: 'h'=byte1, 'é'=bytes2-3, 'l'=byte4
        result = REPLy.truncate_output(s, 3)
        @test endswith(result, REPLy.OUTPUT_TRUNCATION_MARKER)
        @test isvalid(result)  # result must be valid UTF-8
        @test startswith(result, "hé")  # prevind(s,4)=2, so s[1:2]="hé" (3 bytes)
    end

    @testset "truncate_output rejects non-positive max_bytes" begin
        @test_throws ArgumentError REPLy.truncate_output("hello", 0)
        @test_throws ArgumentError REPLy.truncate_output("hello", -1)
    end
end
