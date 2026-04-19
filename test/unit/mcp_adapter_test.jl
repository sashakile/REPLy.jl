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

        eval_tool = only(filter(tool -> tool["name"] == "julia_eval", tools))
        @test eval_tool["inputSchema"]["required"] == ["code"]
        @test haskey(eval_tool["inputSchema"]["properties"], "timeout_ms")
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
