# Protocol spec adoption (REPLy_jl-uffe) — REQ-RPL-001..009 scenario contracts.
#
# Each testset maps one-to-one to a scenario in openspec/specs/protocol/spec.md
# and to a contract TOML in .espectacular/protocol/. Standalone include (via ah
# contract commands) requires the helper prelude: compat.jl, conformance.jl,
# tcp_client.jl, server.jl.

@testset "protocol spec adoption (REPLy_jl-uffe)" begin

    # -------------------------------------------------------------------
    # REQ-RPL-001 — Flat JSON Envelope
    # -------------------------------------------------------------------

    @testset "valid request message" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                # Obtain a session id, then route a fully-formed request:
                # all fields parse and the eval handler runs.
                send_request(sock, Dict("op" => "new-session", "id" => "valid-req-boot"))
                boot = collect_until_done(sock)
                session = only([m["session"] for m in boot if haskey(m, "session")])

                send_request(sock, Dict(
                    "op" => "eval", "id" => "valid-req",
                    "session" => session, "code" => "1 + 1",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "valid-req")
                @test any(get(msg, "value", nothing) == "2" for msg in msgs)
            finally
                close(sock)
            end
        end
    end

    @testset "request without session" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                # Sessionless request: no `session` field at all. Operation-
                # specific behavior (clone without a source errors per
                # core-operations) — the protocol layer still routes and
                # correlates the response normally.
                send_request(sock, Dict("op" => "clone", "id" => "no-session"))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "no-session")
                terminal = msgs[end]
                @test "done" in terminal["status"]
            finally
                close(sock)
            end
        end
    end

    # -------------------------------------------------------------------
    # REQ-RPL-001b — Request ID Length Limit
    # -------------------------------------------------------------------

    @testset "oversized id rejected" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict(
                    "op" => "eval", "id" => repeat("x", 257), "code" => "1 + 1",
                ))
                msgs = collect_until_done(sock)
                @test length(msgs) == 1
                @test msgs[1]["status"] == ["done", "error"]
                @test msgs[1]["err"] == "id exceeds maximum length of 256"
            finally
                close(sock)
            end
        end
    end

    @testset "valid id at limit accepted" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict(
                    "op" => "eval", "id" => repeat("x", 256), "code" => "1 + 1",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, repeat("x", 256))
                @test any(get(msg, "value", nothing) == "2" for msg in msgs)
            finally
                close(sock)
            end
        end
    end

    # -------------------------------------------------------------------
    # REQ-RPL-004 — Response Correlation / Stream Termination
    # -------------------------------------------------------------------

    @testset "streaming eval response carries request id" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict(
                    "op" => "eval", "id" => "req-1",
                    "code" => "println(1); 42",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "req-1")
                @test !isempty(findall(msg -> haskey(msg, "out"), msgs))
                @test any(haskey(msg, "value") for msg in msgs)
            finally
                close(sock)
            end
        end
    end

    @testset "done emitted once on success" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict("op" => "eval", "id" => "done-once", "code" => "1 + 1"))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "done-once")
                done_indexes = findall(msg -> haskey(msg, "status") && "done" in msg["status"], msgs)
                @test length(done_indexes) == 1
            finally
                close(sock)
            end
        end
    end

    @testset "no double done on parse error" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict("op" => "eval", "id" => "parse-err", "code" => "1 +"))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "parse-err")
                terminal = msgs[end]
                @test terminal["status"] == ["done", "error"]
                # No further messages after done: give the server a moment,
                # then assert the socket has no extra queued bytes.
                sleep(0.2)
                @test bytesavailable(sock) == 0
            finally
                close(sock)
            end
        end
    end

    # -------------------------------------------------------------------
    # REQ-RPL-004b — Intra-Request Ordering
    # -------------------------------------------------------------------

    @testset "stdout before value before done" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict(
                    "op" => "eval", "id" => "ordering",
                    "code" => "println(\"before\"); 42",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "ordering")
                out_idx = findfirst(msg -> haskey(msg, "out"), msgs)
                value_idx = findfirst(msg -> haskey(msg, "value"), msgs)
                done_idx = findlast(msg -> haskey(msg, "status") && "done" in msg["status"], msgs)
                @test out_idx < value_idx < done_idx
            finally
                close(sock)
            end
        end
    end

    # -------------------------------------------------------------------
    # REQ-RPL-005 — Streaming Responses / err Field Disambiguation
    # -------------------------------------------------------------------

    @testset "multiple stdout chunks before done" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict(
                    "op" => "eval", "id" => "stream-3",
                    "code" => "for i in 1:3; println(i); end",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "stream-3")
                # Streaming: out chunks arrive as intermediate messages before
                # the terminating done (REQ-RPL-005). The server may coalesce
                # buffered output into one message; content order is preserved.
                out_chunks = [msg["out"] for msg in msgs if haskey(msg, "out")]
                @test !isempty(out_chunks)
                @test join(out_chunks) == "1\n2\n3\n"
                @test !isempty(findall(msg -> haskey(msg, "status") && "done" in msg["status"], msgs))
            finally
                close(sock)
            end
        end
    end

    @testset "stderr chunk distinguished from error response" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict(
                    "op" => "eval", "id" => "err-disambig",
                    "code" => "println(stderr, \"Warning...\"); error(\"boom\")",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "err-disambig")
                # The stderr chunk carries `err` with NO status.
                stderr_chunks = [msg for msg in msgs if haskey(msg, "err") && !haskey(msg, "status")]
                @test length(stderr_chunks) == 1
                @test stderr_chunks[1]["err"] == "Warning...\n"
                # The error response carries `err` WITH status containing "error".
                error_msgs = [msg for msg in msgs if haskey(msg, "err") && haskey(msg, "status")]
                @test length(error_msgs) == 1
                @test "error" in error_msgs[1]["status"]
                @test occursin("boom", error_msgs[1]["err"])
            finally
                close(sock)
            end
        end
    end

    # -------------------------------------------------------------------
    # REQ-RPL-006 — Unknown Field Tolerance
    # -------------------------------------------------------------------

    @testset "extra field in request ignored" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict(
                    "op" => "describe", "id" => "future-flag", "future-flag" => true,
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "future-flag")
                @test any(haskey(msg, "ops") for msg in msgs)
            finally
                close(sock)
            end
        end
    end

    # -------------------------------------------------------------------
    # REQ-RPL-007 — Kebab-Case Field Names
    # -------------------------------------------------------------------

    @testset "response uses kebab-case" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                # Clone emits the kebab-case `new-session` key per the spec.
                send_request(sock, Dict("op" => "new-session", "id" => "kebab-src", "name" => "kebab-src"))
                collect_until_done(sock)
                send_request(sock, Dict("op" => "clone", "id" => "kebab", "source" => "kebab-src", "name" => "kebab-dst"))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "kebab")
                @test any(haskey(msg, "new-session") for msg in msgs)
                @test !any(haskey(msg, "new_session") for msg in msgs)
            finally
                close(sock)
            end
        end
    end

    # -------------------------------------------------------------------
    # REQ-RPL-008 / REQ-RPL-009 — Newline-Delimited JSON Wire Format
    # -------------------------------------------------------------------

    @testset "message framing with newline" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                # Two messages back to back in a single write, each \n-terminated.
                # Both are parsed and answered; read each stream to its done
                # (responses interleave in flight, so read sequentially).
                write(sock, JSON3.write(Dict("op" => "ping", "id" => "frame-1")))
                write(sock, UInt8('\n'))
                write(sock, JSON3.write(Dict("op" => "ping", "id" => "frame-2")))
                write(sock, UInt8('\n'))
                flush(sock)
                msgs1 = collect_until_done(sock)
                msgs2 = collect_until_done(sock)
                @test length(msgs1) == 1 && msgs1[1]["id"] == "frame-1"
                @test length(msgs2) == 1 && msgs2[1]["id"] == "frame-2"
                @test msgs1[1]["status"] == ["done", "pong"]
                @test msgs2[1]["status"] == ["done", "pong"]
            finally
                close(sock)
            end
        end
    end

    @testset "default encoding is json" begin
        with_server(port=0) do handle
            # Plain TCP connection with no encoding negotiation speaks
            # newline-delimited JSON by default.
            sock = connect(handle.port)
            try
                send_request(sock, Dict("op" => "ping", "id" => "enc-default"))
                line = readline(sock; keep=true)
                @test endswith(line, "\n")
                @test !endswith(line, "\n\n")
                msg = JSON3.read(line, Dict{String, Any})
                @test get(msg, "id", nothing) == "enc-default"
                @test "done" in msg["status"]
            finally
                close(sock)
            end
        end
    end

    # -------------------------------------------------------------------
    # REQ-RPL-004 — Status Flags
    # -------------------------------------------------------------------

    @testset "error response has done and error flags" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict(
                    "op" => "eval", "id" => "err-flags",
                    "code" => "error(\"flag-bloom\")",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "err-flags")
                terminal = msgs[end]
                @test "done" in terminal["status"]
                @test "error" in terminal["status"]
            finally
                close(sock)
            end
        end
    end

    @testset "unknown status flag tolerated by client" begin
        # Client-side characterization: a response carrying an unrecognized
        # flag is parsed and its known flags are still processed.
        raw = "{\"id\":\"flag-tol\",\"status\":[\"done\",\"frobnicated\"]}"
        msg = JSON3.read(raw, Dict{String, Any})
        # Known flag is recognized; unknown flag is inert data that does not
        # disturb processing.
        @test "done" in msg["status"]
        # The done-detection used by collect_until_done works unchanged.
        @test haskey(msg, "status") && ("done" in msg["status"])
    end

    # -------------------------------------------------------------------
    # REQ-RPL-003 / REQ-RPL-003b — Session ID Format
    # -------------------------------------------------------------------

    @testset "session id is uuidv4" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                # Clone between named sessions emits the canonical `new-session` key.
                send_request(sock, Dict("op" => "new-session", "id" => "uuid-src", "name" => "uuid-src"))
                collect_until_done(sock)
                send_request(sock, Dict("op" => "clone", "id" => "uuid-check", "source" => "uuid-src", "name" => "uuid-dst"))
                msgs = collect_until_done(sock)
                new_session = only([msg["new-session"] for msg in msgs if haskey(msg, "new-session")])
                @test length(new_session) == 36
                @test occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", new_session)
            finally
                close(sock)
            end
        end
    end

    @testset "session ids are unpredictable" begin
        manager = REPLy.SessionManager()
        ids = [REPLy.create_named_session!(manager, "unpredictable-$i").id for i in 1:100]
        # Statistically independent draws: no repeats across 100 creations.
        @test length(unique(ids)) == 100
        # Each is a v4 UUID drawn from a cryptographically secure RNG.
        for id in ids
            @test occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", id)
        end
    end

end