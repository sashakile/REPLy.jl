@testset "eval middleware" begin
    @testset "buffered stdout is emitted before value and done" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-stdout",
            "code" => "print(\"hello\"); println(\" world\"); 1 + 1",
        ))

        assert_conformance(msgs, "eval-stdout")
        out_msgs = filter(msg -> haskey(msg, "out"), msgs)
        @test !isempty(out_msgs)
        @test join(getindex.(out_msgs, "out")) == "hello world\n"
        @test only(filter(msg -> haskey(msg, "value"), msgs))["value"] == "2"
    end

    @testset "buffered stderr is emitted without status before value and done" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-stderr",
            "code" => "print(stderr, \"warn\"); 3 + 4",
        ))

        assert_conformance(msgs, "eval-stderr")
        err_msgs = filter(msg -> haskey(msg, "err") && !haskey(msg, "status"), msgs)
        @test !isempty(err_msgs)
        @test join(getindex.(err_msgs, "err")) == "warn"
        @test all(!haskey(msg, "status") for msg in err_msgs)
        @test only(filter(msg -> haskey(msg, "value"), msgs))["value"] == "7"
    end

    @testset "empty code returns repr(nothing) and done only" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-empty",
            "code" => "   ",
        ))

        assert_conformance(msgs, "eval-empty")
        @test length(msgs) == 2
        @test msgs[1]["value"] == "nothing"
        @test msgs[2]["status"] == ["done"]
    end

    @testset "runtime error responses are not mistaken for buffered stderr messages" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-error",
            "code" => "error(\"boom\")",
        ))

        assert_conformance(msgs, "eval-error")
        @test length(msgs) == 1
        @test haskey(msgs[1], "status")
        @test "error" in msgs[1]["status"]
        @test occursin("boom", msgs[1]["err"])
    end

    @testset "multi-expression eval returns last expression like the REPL" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-multi",
            "code" => "x = 1\ny = x + 1\ny",
        ))

        assert_conformance(msgs, "eval-multi")
        value_msg = only(filter(msg -> haskey(msg, "value"), msgs))
        @test value_msg["value"] == "2"
    end

    @testset "broken result show methods fall back instead of crashing" begin
        struct BrokenShow end
        Base.show(io::IO, ::BrokenShow) = error("broken show")
        Base.show(io::IO, ::MIME"text/plain", ::BrokenShow) = error("broken plain show")

        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-broken-repr",
            "code" => "Main.BrokenShow()",
        ))

        assert_conformance(msgs, "eval-broken-repr")
        value_msg = only(filter(msg -> haskey(msg, "value"), msgs))
        @test value_msg["value"] == "<repr failed: BrokenShow>"
    end

    @testset "broken showerror methods fall back instead of crashing" begin
        struct BrokenEvalError <: Exception end
        Base.show(io::IO, ::BrokenEvalError) = error("broken show")

        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-broken-showerror",
            "code" => "throw(Main.BrokenEvalError())",
        ))

        assert_conformance(msgs, "eval-broken-showerror")
        @test length(msgs) == 1
        @test only(msgs)["err"] == "<showerror failed: BrokenEvalError>"
        @test only(msgs)["ex"]["message"] == "<showerror failed: BrokenEvalError>"
    end

    @testset "concurrent evals keep stdout isolated per request" begin
        handler = REPLy.build_handler()

        task1 = @async handler(Dict(
            "op" => "eval",
            "id" => "eval-concurrent-1",
            "code" => "yield(); println(\"task-1\"); \"task-1\"",
        ))

        task2 = @async handler(Dict(
            "op" => "eval",
            "id" => "eval-concurrent-2",
            "code" => "yield(); println(\"task-2\"); \"task-2\"",
        ))

        msgs1 = fetch(task1)
        msgs2 = fetch(task2)

        assert_conformance(msgs1, "eval-concurrent-1")
        assert_conformance(msgs2, "eval-concurrent-2")

        out1 = join(getindex.(filter(msg -> haskey(msg, "out"), msgs1), "out"))
        out2 = join(getindex.(filter(msg -> haskey(msg, "out"), msgs2), "out"))

        @test out1 == "task-1\n"
        @test out2 == "task-2\n"
    end

    @testset "large repr output is truncated with marker" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], REPLy.create_ephemeral_session!(manager))
        request = Dict("op" => "eval", "id" => "trunc-large", "code" => "repeat(\"x\", 10_000)")

        responses = REPLy.handle_message(
            REPLy.EvalMiddleware(; max_repr_bytes=20),
            request,
            _ -> nothing,
            ctx,
        )

        value_msg = only(filter(m -> haskey(m, "value"), responses))
        @test endswith(value_msg["value"], REPLy.OUTPUT_TRUNCATION_MARKER)
        @test ncodeunits(value_msg["value"]) <= 20 + ncodeunits(REPLy.OUTPUT_TRUNCATION_MARKER)
    end

    @testset "small repr output is not truncated" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], REPLy.create_ephemeral_session!(manager))
        request = Dict("op" => "eval", "id" => "trunc-small", "code" => "42")

        responses = REPLy.handle_message(
            REPLy.EvalMiddleware(; max_repr_bytes=1000),
            request,
            _ -> nothing,
            ctx,
        )

        value_msg = only(filter(m -> haskey(m, "value"), responses))
        @test value_msg["value"] == "42"
    end

    @testset "large buffered output completes without deadlock" begin
        handler = REPLy.build_handler()
        task = @async handler(Dict(
            "op" => "eval",
            "id" => "eval-large-output",
            "code" => "print(repeat(\"a\", 200000)); 1",
        ))

        status = timedwait(() -> istaskdone(task), 5.0)
        @test status == :ok

        msgs = fetch(task)
        assert_conformance(msgs, "eval-large-output")
        out_msgs = filter(msg -> haskey(msg, "out"), msgs)
        @test sum(ncodeunits(msg["out"]) for msg in out_msgs) == 200000
        @test only(filter(msg -> haskey(msg, "value"), msgs))["value"] == "1"
    end
end
