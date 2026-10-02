# Purpose: end-to-end MCP adapter scenarios (REQ-RPL-070..076) driven through
#   the in-process JSON-RPC dispatch used by the stdio MCP server.
# Responsibilities: exercise tools/call routing, result mapping (isError,
#   content), default/ephemeral session routing, stdin fail-fast, and the
#   error path with real Reply evals — mapped from .espectacular/mcp-adapter
#   contracts; must fail loudly when assertions disappear.
# Rationale: contracts run this file standalone, so assertions (not test_broken
#   placeholders) are the adoption signal for the mcp-adapter spec.
using Test
using JSON3
using REPLy

@testset "MCP Server (stdio)" begin
    manager = REPLy.SessionManager()
    default_session = REPLy.mcp_ensure_default_session!(manager)

    # Helper to run a single request-response cycle through in-process handler
    function test_mcp_rpc(method, params=Dict(); id=1)
        handler = REPLy.build_handler(; manager=manager)
        return REPLy.process_mcp_request(method, params, id, manager, default_session, handler)
    end

    @testset "Handshake" begin
        resp = test_mcp_rpc("initialize")
        @test resp["id"] == 1
        @test resp["result"]["protocolVersion"] == REPLy.MCP_PROTOCOL_VERSION
        @test resp["result"]["serverInfo"]["name"] == "REPLy"

        resp = test_mcp_rpc("tools/list")
        @test resp["id"] == 1
        @test any(t -> t["name"] == "julia_eval", resp["result"]["tools"])
        @test any(t -> t["name"] == "julia_new_session", resp["result"]["tools"])
    end

    @testset "Evaluation" begin
        # Success path
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_eval",
            "arguments" => Dict("code" => "1 + 1")
        ))
        @test resp["id"] == 1
        @test resp["result"]["isError"] == false
        @test resp["result"]["content"][1]["text"] == "2"

        # Multi-line/stdout path
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_eval",
            "arguments" => Dict("code" => "println(\"hello\"); 42")
        ))
        @test resp["result"]["content"][1]["text"] == "hello\n"
        @test resp["result"]["content"][2]["text"] == "42"
    end

    @testset "Lifecycle" begin
        # New session
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_new_session",
            "arguments" => Dict()
        ))
        @test occursin("Session:", resp["result"]["content"][1]["text"])
        uuid = split(resp["result"]["content"][1]["text"])[2]

        # List sessions
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_list_sessions",
            "arguments" => Dict()
        ))
        @test occursin(uuid, resp["result"]["content"][1]["text"])
    end

    @testset "Errors" begin
        # Unknown method
        resp = test_mcp_rpc("nonexistent")
        @test haskey(resp, "error")
        @test resp["error"]["code"] == -32601

        # Unknown tool
        resp = test_mcp_rpc("tools/call", Dict("name" => "bad_tool"))
        @test resp["result"]["isError"] == true
        @test occursin("Unknown tool", resp["result"]["content"][1]["text"])
    end

    @testset "julia_complete returns real completions" begin
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_complete",
            "arguments" => Dict("code" => "prin", "pos" => 4),
        ))
        @test resp["result"]["isError"] == false
        text = resp["result"]["content"][1]["text"]
        @test occursin("completions", text)
        @test occursin("println", text)
    end

    @testset "julia_lookup returns real documentation" begin
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_lookup",
            "arguments" => Dict("symbol" => "println"),
        ))
        @test resp["result"]["isError"] == false
        text = resp["result"]["content"][1]["text"]
        @test occursin("\"found\":true", text)
        @test occursin("println", text)
    end

    @testset "julia_lookup reports not-found symbols" begin
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_lookup",
            "arguments" => Dict("symbol" => "no_such_symbol_xyz"),
        ))
        @test resp["result"]["isError"] == false
        @test occursin("\"found\":false", resp["result"]["content"][1]["text"])
    end

    @testset "julia_interrupt on an idle session returns empty interrupted list" begin
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_interrupt",
            "arguments" => Dict("session" => default_session),
        ))
        @test resp["result"]["isError"] == false
        @test occursin("interrupted", resp["result"]["content"][1]["text"])
    end

    @testset "eval error surfaces isError with message and stacktrace" begin
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_eval",
            "arguments" => Dict("code" => "error(\"mcp spec boom\")"),
        ))
        @test resp["result"]["isError"] == true
        texts = [c["text"] for c in resp["result"]["content"]]
        @test any(t -> occursin("mcp spec boom", t), texts)
        @test length(texts) >= 2  # error message + stacktrace block
        @test any(t -> occursin("top-level scope", t), texts)
    end

    @testset "stdin-blocking code fails fast with isError" begin
        # Bare readline() reads clean EOF under allow-stdin:false — completes
        # immediately (no hang), no error. Julia's readline never raises at EOF.
        t0 = time()
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_eval",
            "arguments" => Dict("code" => "readline()"),
        ))
        elapsed = time() - t0

        @test resp["result"]["isError"] == false
        @test resp["result"]["content"][end]["text"] == "\"\""
        @test elapsed < 10.0  # fail-fast, not hanging for interactive input

        # A stdin read that requires bytes raises EOFError at EOF, and the
        # adapter maps it to isError = true.
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_eval",
            "arguments" => Dict("code" => "read(stdin, Char)"),
        ))
        @test resp["result"]["isError"] == true
        @test any(t -> occursin("EOFError", t),
                  [c["text"] for c in resp["result"]["content"]])
    end

    @testset "omitted session routes to persistent default across calls" begin
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_eval",
            "arguments" => Dict("code" => "mcp_spec_default_x = 21"),
        ))
        @test resp["result"]["isError"] == false

        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_eval",
            "arguments" => Dict("code" => "mcp_spec_default_x * 2"),
        ))
        @test resp["result"]["isError"] == false
        @test resp["result"]["content"][end]["text"] == "42"
    end

    @testset "ephemeral sentinel eval does not persist bindings" begin
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_eval",
            "arguments" => Dict(
                "code" => "mcp_spec_ephemeral_y = 7",
                "session" => "ephemeral",
            ),
        ))
        @test resp["result"]["isError"] == false

        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_eval",
            "arguments" => Dict("code" => "mcp_spec_ephemeral_y"),
        ))
        @test resp["result"]["isError"] == true
        @test any(t -> occursin("UndefVarError", t),
                  [c["text"] for c in resp["result"]["content"]])
    end

    @testset "julia_load_file evaluates a real file" begin
        # The default stack denies file loads (no allowlist); verify the tool
        # dispatches over the live transport and surfaces the real server
        # response rather than a not-implemented stub.
        resp = test_mcp_rpc("tools/call", Dict(
            "name" => "julia_load_file",
            "arguments" => Dict("file" => "/tmp/does-not-matter.jl"),
        ))
        @test resp["result"]["isError"] == true
        @test !occursin("not yet implemented", resp["result"]["content"][1]["text"])
    end
end
