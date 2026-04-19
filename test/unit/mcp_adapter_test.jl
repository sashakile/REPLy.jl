@testset "mcp adapter" begin
    @testset "initialize payload declares supported protocol version" begin
        result = REPLy.mcp_initialize_result()

        @test result["protocolVersion"] == "2024-11-05"
        @test result["capabilities"] == Dict{String, Any}()
        @test result["serverInfo"] == Dict(
            "name" => "REPLy",
            "version" => REPLy.version_string(),
        )
    end

    @testset "tool catalog includes all eight tools" begin
        tools = REPLy.mcp_tools()
        names = getindex.(tools, "name")

        @test names == [
            "julia_eval",
            "julia_complete",
            "julia_lookup",
            "julia_load_file",
            "julia_interrupt",
            "julia_new_session",
            "julia_list_sessions",
            "julia_close_session",
        ]

        by_name = Dict(tool["name"] => tool for tool in tools)
        @test by_name["julia_eval"]["inputSchema"]["required"] == ["code"]
        @test Set(keys(by_name["julia_eval"]["inputSchema"]["properties"])) == Set(["code", "session", "module", "timeout_ms"])
        @test by_name["julia_complete"]["inputSchema"]["required"] == ["code", "pos"]
        @test Set(keys(by_name["julia_complete"]["inputSchema"]["properties"])) == Set(["code", "pos", "session"])
        @test by_name["julia_lookup"]["inputSchema"]["required"] == ["symbol"]
        @test Set(keys(by_name["julia_lookup"]["inputSchema"]["properties"])) == Set(["symbol", "module", "session"])
        @test by_name["julia_load_file"]["inputSchema"]["required"] == ["file"]
        @test Set(keys(by_name["julia_load_file"]["inputSchema"]["properties"])) == Set(["file", "session"])
        @test by_name["julia_interrupt"]["inputSchema"]["required"] == ["session"]
        @test Set(keys(by_name["julia_interrupt"]["inputSchema"]["properties"])) == Set(["session", "interrupt_id"])
        @test by_name["julia_new_session"]["inputSchema"]["required"] == String[]
        @test by_name["julia_list_sessions"]["inputSchema"]["required"] == String[]
        @test by_name["julia_close_session"]["inputSchema"]["required"] == ["session"]
    end

    @testset "eval request uses default session and disables stdin" begin
        request = REPLy.mcp_eval_request("req-1", Dict(
            "code" => "1 + 1",
            "module" => "Main",
            "timeout_ms" => 250,
        ); default_session="session-default")

        @test request == Dict(
            "op" => "eval",
            "id" => "req-1",
            "code" => "1 + 1",
            "session" => "session-default",
            "module" => "Main",
            "timeout-ms" => 250,
            "allow-stdin" => false,
        )
    end

    @testset "eval request omits session for ephemeral sentinel" begin
        request = REPLy.mcp_eval_request("req-2", Dict(
            "code" => "1 + 1",
            "session" => "ephemeral",
        ); default_session="session-default")

        @test !haskey(request, "session")
        @test request["allow-stdin"] == false
    end

    @testset "eval request rejects invalid adapter arguments" begin
        @test_throws ArgumentError REPLy.mcp_eval_request("bad-code", Dict(); default_session="session-default")
        @test_throws ArgumentError REPLy.mcp_eval_request("bad-session", Dict("code" => "1 + 1", "session" => 1); default_session="session-default")
        @test_throws ArgumentError REPLy.mcp_eval_request("bad-module", Dict("code" => "1 + 1", "module" => 2); default_session="session-default")
        @test_throws ArgumentError REPLy.mcp_eval_request("bad-timeout-type", Dict("code" => "1 + 1", "timeout_ms" => "250"); default_session="session-default")
        @test_throws ArgumentError REPLy.mcp_eval_request("bad-timeout-zero", Dict("code" => "1 + 1", "timeout_ms" => 0); default_session="session-default")
        @test_throws ArgumentError REPLy.mcp_eval_request("bad-timeout-negative", Dict("code" => "1 + 1", "timeout_ms" => -5); default_session="session-default")
    end

    @testset "reply stream is collected until done" begin
        io = IOBuffer(
            "{\"id\":\"req-3\",\"out\":\"hi\\n\"}\n" *
            "{\"id\":\"req-3\",\"value\":\"2\"}\n" *
            "{\"id\":\"req-3\",\"status\":[\"done\"]}\n",
        )
        transport = REPLy.JSONTransport(io, ReentrantLock())

        msgs = REPLy.collect_reply_stream(transport, "req-3")

        assert_conformance(msgs, "req-3")
        @test msgs[1]["out"] == "hi\n"
        @test msgs[2]["value"] == "2"
    end

    @testset "interleaved reply streams are buffered by id" begin
        io = IOBuffer(
            "{\"id\":\"req-a\",\"out\":\"hello\\n\"}\n" *
            "{\"id\":\"req-b\",\"value\":\"99\"}\n" *
            "{\"id\":\"req-a\",\"status\":[\"done\"]}\n" *
            "{\"id\":\"req-b\",\"status\":[\"done\"]}\n",
        )
        transport = REPLy.JSONTransport(io, ReentrantLock())
        pending = Dict{String, Vector{Dict{String, Any}}}()

        msgs_a = REPLy.collect_reply_stream(transport, "req-a"; pending)
        msgs_b = REPLy.collect_reply_stream(transport, "req-b"; pending)

        assert_conformance(msgs_a, "req-a")
        assert_conformance(msgs_b, "req-b")
        @test msgs_a[1]["out"] == "hello\n"
        @test msgs_b[1]["value"] == "99"
        @test isempty(pending)
    end

    @testset "stdout and terminal value become non-error tool content" begin
        result = REPLy.reply_stream_to_mcp_result([
            Dict("id" => "req-4", "out" => "hello\n"),
            Dict("id" => "req-4", "value" => "2"),
            Dict("id" => "req-4", "status" => ["done"]),
        ])

        @test result == Dict(
            "isError" => false,
            "content" => [
                Dict("type" => "text", "text" => "hello\n"),
                Dict("type" => "text", "text" => "2"),
            ],
        )
    end

    @testset "error statuses map to error tool results" begin
        timed_out = REPLy.reply_stream_to_mcp_result([
            Dict("id" => "req-5", "status" => ["done", "error", "timeout"], "err" => "Eval timed out after 10 ms"),
        ])
        interrupted = REPLy.reply_stream_to_mcp_result([
            Dict("id" => "req-6", "status" => ["done", "interrupted"]),
        ])
        missing_session = REPLy.reply_stream_to_mcp_result([
            Dict("id" => "req-7", "status" => ["done", "error", "session-not-found"], "err" => "Unknown session: abc"),
        ])

        @test timed_out == Dict(
            "isError" => true,
            "content" => [Dict("type" => "text", "text" => "Evaluation timed out")],
        )
        @test interrupted == Dict(
            "isError" => true,
            "content" => [Dict("type" => "text", "text" => "Interrupted")],
        )
        @test missing_session == Dict(
            "isError" => true,
            "content" => [Dict("type" => "text", "text" => "Unknown session: abc")],
        )
    end

    @testset "structured reply errors include error message and stacktrace" begin
        result = REPLy.reply_stream_to_mcp_result([
            Dict("id" => "req-8", "status" => ["done", "error"], "err" => "UndefVarError: y not defined", "stacktrace" => [Dict("func" => "top-level scope", "file" => "none", "line" => 1)]),
        ])

        @test result["isError"] == true
        @test length(result["content"]) == 2
        @test result["content"][1] == Dict("type" => "text", "text" => "UndefVarError: y not defined")
        @test occursin("top-level scope", result["content"][2]["text"])
    end
end
