@testset "eval middleware" begin
    @testset "stdout chunks are emitted before value and done" begin
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

    @testset "stderr chunks are emitted without status before value and done" begin
        msgs = REPLy.build_handler()(Dict(
            "op" => "eval",
            "id" => "eval-stderr",
            "code" => "print(stderr, \"warn\"); 3 + 4",
        ))

        assert_conformance(msgs, "eval-stderr")
        err_chunks = filter(msg -> haskey(msg, "err") && !haskey(msg, "status"), msgs)
        @test !isempty(err_chunks)
        @test join(getindex.(err_chunks, "err")) == "warn"
        @test all(!haskey(msg, "status") for msg in err_chunks)
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

    @testset "runtime error responses are not mistaken for stderr chunks" begin
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
end
