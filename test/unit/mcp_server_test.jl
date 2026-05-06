using Test
using JSON3
using REPLy
using Sockets

@testset "MCP Server (stdio)" begin
    manager = REPLy.SessionManager()
    default_session = REPLy.mcp_ensure_default_session!(manager)

    # Helper to run a single request-response cycle through serve_mcp logic
    function test_mcp_rpc(method, params=Dict(); id=1)
        # For julia_eval, we need a running server.
        server = serve(host=ip"127.0.0.1", port=0, manager=manager)
        port = server_port(server)

        try
            resp = REPLy.process_mcp_request(method, params, id, manager, default_session, port)
            return resp
        finally
            close(server)
        end
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

    @testset "Stub tools return isError" begin
        for tool in ("julia_load_file", "julia_interrupt", "julia_complete", "julia_lookup")
            resp = test_mcp_rpc("tools/call", Dict("name" => tool, "arguments" => Dict()))
            @test resp["result"]["isError"] == true
            @test occursin("not yet implemented", resp["result"]["content"][1]["text"])
        end
    end
end
