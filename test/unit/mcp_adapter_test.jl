# A transport that blocks on receive until explicitly closed — used to test timeout paths.
mutable struct ChannelTransport <: REPLy.AbstractTransport
    ch::Channel{Union{Nothing, Dict{String, Any}}}
    is_open::Ref{Bool}
end
ChannelTransport() = ChannelTransport(Channel{Union{Nothing, Dict{String, Any}}}(16), Ref(true))

function REPLy.receive(t::ChannelTransport; kwargs...)
    t.is_open[] || return nothing
    try
        return take!(t.ch)
    catch
        return nothing
    end
end
Base.isopen(t::ChannelTransport) = t.is_open[]
function Base.close(t::ChannelTransport)
    t.is_open[] = false
    close(t.ch)
end

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
        ); default_session="session-default")

        @test request == Dict(
            "op" => "eval",
            "id" => "req-1",
            "code" => "1 + 1",
            "session" => "session-default",
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
    end

    @testset "eval request rejects not-yet-supported module and timeout_ms fields" begin
        @test_throws ArgumentError REPLy.mcp_eval_request("has-module", Dict("code" => "1 + 1", "module" => "Main"); default_session="session-default")
        @test_throws ArgumentError REPLy.mcp_eval_request("has-timeout", Dict("code" => "1 + 1", "timeout_ms" => 250); default_session="session-default")
    end

    @testset "mcp_stub_result returns not-yet-implemented error for unimplemented tools" begin
        for tool in ["julia_complete", "julia_lookup", "julia_load_file", "julia_interrupt"]
            result = REPLy.mcp_stub_result(tool)
            @test result["isError"] == true
            @test occursin("not yet implemented", result["content"][1]["text"])
            @test occursin(tool, result["content"][1]["text"])
        end
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

    @testset "collect_reply_stream times out and returns synthetic timeout message" begin
        transport = ChannelTransport()

        t0 = time()
        msgs = REPLy.collect_reply_stream(transport, "stuck-req"; timeout_seconds=0.1)
        elapsed = time() - t0

        @test elapsed < 1.0
        @test length(msgs) == 1
        @test msgs[1]["id"] == "stuck-req"
        @test "done" in msgs[1]["status"]
        @test "timeout" in msgs[1]["status"]
    end

    @testset "collect_reply_stream rejects non-positive timeout_seconds" begin
        transport = ChannelTransport()
        @test_throws ArgumentError REPLy.collect_reply_stream(transport, "bad-timeout"; timeout_seconds=0.0)
        @test_throws ArgumentError REPLy.collect_reply_stream(transport, "bad-timeout"; timeout_seconds=-1.0)
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

    @testset "mcp_ensure_default_session! creates a session on first call" begin
        manager = REPLy.SessionManager()
        name = REPLy.mcp_ensure_default_session!(manager)

        @test name isa String
        @test !isnothing(REPLy.lookup_named_session(manager, name))
    end

    @testset "mcp_ensure_default_session! is idempotent — same name, no duplicate" begin
        manager = REPLy.SessionManager()
        name1 = REPLy.mcp_ensure_default_session!(manager)
        name2 = REPLy.mcp_ensure_default_session!(manager)

        @test name1 == name2
        @test length(REPLy.list_named_sessions(manager)) == 1
    end

    @testset "mcp_ensure_default_session! is safe under concurrent calls" begin
        manager = REPLy.SessionManager()
        tasks = [@async REPLy.mcp_ensure_default_session!(manager) for _ in 1:20]
        names = fetch.(tasks)

        @test all(==(REPLy.MCP_DEFAULT_SESSION_NAME), names)
        @test length(REPLy.list_named_sessions(manager)) == 1
    end

    @testset "mcp_new_session_result creates a named session and returns its id" begin
        manager = REPLy.SessionManager()
        result = REPLy.mcp_new_session_result(manager)

        @test result["isError"] == false
        sessions = REPLy.list_named_sessions(manager)
        @test length(sessions) == 1
        @test result["content"][1]["text"] == "Session: $(sessions[1].name)"
    end

    @testset "mcp_list_sessions_result lists all named session names" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "alpha")
        REPLy.create_named_session!(manager, "beta")
        result = REPLy.mcp_list_sessions_result(manager)

        @test result["isError"] == false
        text = result["content"][1]["text"]
        @test occursin("alpha", text)
        @test occursin("beta", text)
    end

    @testset "mcp_list_sessions_result returns empty marker when no sessions exist" begin
        manager = REPLy.SessionManager()
        result = REPLy.mcp_list_sessions_result(manager)

        @test result["isError"] == false
        @test result["content"][1]["text"] == "[]"
    end

    @testset "mcp_close_session_result closes an existing session" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "to-close")
        result = REPLy.mcp_close_session_result(manager, "to-close")

        @test result["isError"] == false
        @test isnothing(REPLy.lookup_named_session(manager, "to-close"))
    end

    @testset "mcp_close_session_result errors for unknown session" begin
        manager = REPLy.SessionManager()
        result = REPLy.mcp_close_session_result(manager, "nonexistent")

        @test result["isError"] == true
        @test occursin("nonexistent", result["content"][1]["text"])
    end
end
