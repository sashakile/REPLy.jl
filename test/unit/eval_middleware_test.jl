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
