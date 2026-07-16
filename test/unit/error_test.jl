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

    @testset "internal_error_response returns stable code + correlation id only" begin
        # Server-internal failures must NOT leak stack traces or exception
        # type details to the client. Only a stable error message and a
        # correlation id for server-side log lookup. Full trace is logged
        # server-side at Error level.
        ex = ErrorException("something went wrong deep inside")
        bt = try
            error("capture")
        catch
            catch_backtrace()
        end

        logger = TestLogger()
        resp = with_logger(logger) do
            REPLy.internal_error_response("req-1", ex; bt=bt)
        end

        @test resp["id"] == "req-1"
        @test Set(resp["status"]) == Set(["done", "error"])
        @test occursin("Internal server error", resp["err"])
        # Must have a correlation id (non-empty string) for log correlation
        @test haskey(resp, "correlation-id")
        @test resp["correlation-id"] isa AbstractString
        @test !isempty(resp["correlation-id"])
        # Must NOT leak exception type or stack trace to client
        @test !haskey(resp, "ex")
        @test !haskey(resp, "stacktrace")
        # Server-side log must include correlation_id and exception
        @test length(logger.logs) == 1
        @test logger.logs[1].level == Logging.Error
        @test occursin("Internal handler failure", logger.logs[1].message)
        @test logger.logs[1].kwargs[:correlation_id] == resp["correlation-id"]
        @test haskey(logger.logs[1].kwargs, :exception)
    end

    @testset "eval_error_response still returns full trace for user eval errors" begin
        # User eval errors must continue to return full exception details
        # and stack traces — this is the expected behavior for eval.
        ex = UndefVarError(:missing_name)
        bt = try
            error("capture")
        catch
            catch_backtrace()
        end
        resp = REPLy.eval_error_response("req-2", ex; bt=bt)

        @test resp["id"] == "req-2"
        @test Set(resp["status"]) == Set(["done", "error"])
        @test haskey(resp, "ex")
        @test resp["ex"]["type"] == "UndefVarError"
        @test haskey(resp, "stacktrace")
        @test resp["stacktrace"] isa Vector
        @test !isempty(resp["stacktrace"])
        # No correlation-id on user-facing errors
        @test !haskey(resp, "correlation-id")
    end

    @testset "internal_error_response opt-in trace exposure on loopback" begin
        # When expose_internal_traces is true (e.g. loopback connection), the
        # response should include the full exception and stacktrace.
        # Server-side @error logging still occurs.
        ex = ErrorException("debug this")
        bt = try
            error("capture")
        catch
            catch_backtrace()
        end

        logger = TestLogger()
        resp = with_logger(logger) do
            REPLy.internal_error_response("req-3", ex; bt=bt, expose_trace=true)
        end

        @test resp["id"] == "req-3"
        @test haskey(resp, "ex")
        @test resp["ex"]["type"] == "ErrorException"
        @test haskey(resp, "stacktrace")
        @test resp["stacktrace"] isa Vector
        @test !isempty(resp["stacktrace"])
        # Still includes correlation id even when trace is exposed
        @test haskey(resp, "correlation-id")
        @test !isempty(resp["correlation-id"])
        # Server-side log includes correlation_id and exception
        @test length(logger.logs) == 1
        @test logger.logs[1].level == Logging.Error
        @test occursin("Internal handler failure", logger.logs[1].message)
        @test logger.logs[1].kwargs[:correlation_id] == resp["correlation-id"]
        @test haskey(logger.logs[1].kwargs, :exception)
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

    @testset "safe_render error counter increments on render failure" begin
        before = REPLy.safe_render_error_count()
        renderer = _ -> error("render boom")
        result = REPLy.safe_render("test", renderer, 42)
        after = REPLy.safe_render_error_count()
        @test result == "<test failed: Int64>"
        @test after == before + 1
    end

    @testset "safe_render returns actual value on success" begin
        before = REPLy.safe_render_error_count()
        result = REPLy.safe_render("show", v -> sprint(show, v), "hello")
        @test result == "\"hello\""
        # Counter should not increment on successful render
        @test REPLy.safe_render_error_count() == before
    end
end
