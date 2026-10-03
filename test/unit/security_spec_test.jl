# Purpose: Map the 20 scenarios of openspec/specs/security/spec.md to
# executable Julia assertions — the contract file for the security spec
# adoption (REPLy_jl-bpiz).
# Responsibilities: One testset per scenario id; e2e over TCP/Unix sockets via
# the shared helpers plus direct ServerState/AuditLog probes; must fail loudly
# when a security requirement regresses (ah maps whole files, not counts).
# Rationale: The security spec is the local-posture contract (loopback default,
# resource enforcement, audit logging, disconnect cleanup, graceful shutdown);
# keeping the mapping in one file makes spec-test correspondence auditable via
# `ah check --run-tests`.

using REPLy
using Test
using Logging
using JSON3
using Sockets
using Dates
using UUIDs

struct GraceExpiryProbe <: REPLy.AbstractMiddleware
    entered::Channel{Nothing}
    release::Channel{Nothing}
end

function REPLy.handle_message(mw::GraceExpiryProbe, msg, next, ctx::REPLy.RequestContext)
    get(msg, "op", nothing) == "grace-expire" || return next(msg)
    put!(mw.entered, nothing)
    take!(mw.release)
    return [Dict{String, Any}("id" => String(msg["id"]), "status" => ["done"])]
end

@testset "security spec" begin

    @testset "non-loopback TCP binding emits warning" begin
        logs = Test.TestLogger()
        server = with_logger(logs) do
            REPLy.serve(; host=ip"0.0.0.0", port=0)
        end
        try
            warns = [string(m.message) for m in logs.logs if m.level == Logging.Warn]
            @test any(m -> occursin("non-loopback", m), warns)
        finally
            close(server)
        end
    end

    @testset "loopback TCP binding emits no warning" begin
        logs = Test.TestLogger()
        server = with_logger(logs) do
            REPLy.serve(; port=0)
        end
        try
            warns = [string(m.message) for m in logs.logs if m.level == Logging.Warn]
            @test !any(m -> occursin("non-loopback", m), warns)
        finally
            close(server)
        end
    end

    @testset "non-owner cannot connect to unix socket" begin
        # CI cannot switch UIDs; the enforceable proxy is the socket file mode:
        # owner-only (0o600) is what excludes other UIDs from connecting.
        with_unix_server() do handle
            @test ispath(handle.path)
            @test stat(handle.path).mode & 0o777 == 0o600
        end
    end

    @testset "eval timeout enforced on reference hardware" begin
        limits = REPLy.ResourceLimits(max_eval_time_ms=300)
        server = REPLy.serve(; port=0, limits=limits)
        try
            client = connect(REPLy.server_port(server))
            try
                t0 = time()
                send_request(client, Dict("op" => "eval", "id" => "to1", "code" => "sleep(30)"))
                msgs = collect_until_done(client; timeout_s=10.0)
                elapsed = time() - t0
                terminal = last(filter(m -> haskey(m, "status"), msgs))
                @test "timeout" in terminal["status"]
                # Delivered promptly after the 0.3 s threshold (spec: ~100 ms
                # p99 on reference hardware; CI bound is deliberately generous
                # but still two orders below the eval's own 30 s duration).
                @test elapsed < 5.0
                @test REPLy.active_count(server.state.gate) == 0
            finally
                isopen(client) && close(client)
            end
        finally
            close(server)
        end
    end

    @testset "eval timeout and manual interrupt collision" begin
        limits = REPLy.ResourceLimits(max_eval_time_ms=400)
        server = REPLy.serve(; port=0, limits=limits)
        try
            client = connect(REPLy.server_port(server))
            try
                send_request(client, Dict("op" => "eval", "id" => "coll", "code" => "sleep(30)"))
                sleep(0.05)
                # Manual interrupt with no interrupt-id cancels the eval.
                send_request(client, Dict("op" => "interrupt", "id" => "coll-int"))
                msgs = collect_until_done(client; timeout_s=10.0)
                terminal = last(filter(m -> haskey(m, "status"), msgs))
                # First termination cause wins; the second is a no-op, so the
                # terminal reflects exactly one of timeout / interrupted.
                @test ("timeout" in terminal["status"]) !=
                      ("interrupted" in terminal["status"])
            finally
                isopen(client) && close(client)
            end
        finally
            close(server)
        end
    end

    @testset "session limit enforced on clone" begin
        limits = REPLy.ResourceLimits(max_sessions=1)
        server = REPLy.serve(; port=0, limits=limits)
        try
            client = connect(REPLy.server_port(server))
            try
                send_request(client, Dict("op" => "new-session", "id" => "sl0",
                    "name" => "base"))
                collect_until_done(client)
                send_request(client, Dict("op" => "clone", "id" => "sl2",
                    "source" => "base", "name" => "copy"))
                msgs = collect_until_done(client)
                terminal = last(filter(m -> haskey(m, "status"), msgs))
                @test "session-limit-reached" in terminal["status"]
                @test terminal["err"] == "Session limit reached"
            finally
                isopen(client) && close(client)
            end
        finally
            close(server)
        end
    end

    @testset "concurrent eval limit enforced with queue" begin
        limits = REPLy.ResourceLimits(max_concurrent_evals=1)
        server = REPLy.serve(; port=0, limits=limits)
        try
            c1 = connect(REPLy.server_port(server))
            c2 = connect(REPLy.server_port(server))
            c3 = connect(REPLy.server_port(server))
            c4 = connect(REPLy.server_port(server))
            try
                send_request(c1, Dict("op" => "eval", "id" => "a1", "code" => "sleep(5)"))
                # a1 occupies the single slot; wait until it is running.
                @test timedwait(() -> REPLy.active_count(server.state.gate) == 1, 5.0) === :ok
                send_request(c2, Dict("op" => "eval", "id" => "b1", "code" => "sleep(5)"))
                send_request(c3, Dict("op" => "eval", "id" => "b2", "code" => "sleep(5)"))
                # FIFO queue capacity is 2x the limit → b1, b2 queued.
                @test timedwait(() -> length(server.state.gate.queue) == 2, 5.0) === :ok
                # b3 is beyond the queue: rejected immediately, not queued.
                send_request(c4, Dict("op" => "eval", "id" => "b3", "code" => "sleep(5)"))
                msgs = collect_until_done(c4; timeout_s=5.0)
                terminal = last(filter(m -> haskey(m, "status"), msgs))
                @test "concurrency-limit-reached" in terminal["status"]
                @test terminal["err"] == "Too many concurrent evals"
            finally
                for c in (c1, c2, c3, c4)
                    isopen(c) && close(c)
                end
            end
        finally
            close(server)
        end
    end

    @testset "oversized message closes connection" begin
        server = REPLy.serve(; port=0, max_message_bytes=100)
        try
            client = connect(REPLy.server_port(server))
            try
                send_request(client, Dict("op" => "eval", "id" => "big1",
                    "code" => repeat("x", 200)))
                # REQ-RPL-047e: connection closes, no response is sent.
                line_ch = Channel{Union{Nothing, String}}(1)
                reader = @async begin
                    try
                        put!(line_ch, readline(client))
                    catch
                        put!(line_ch, nothing)
                    end
                end
                @test timedwait(() -> istaskdone(reader), 5.0) === :ok
                @test take!(line_ch) == ""
                # … and an audit entry is recorded.
                entries = REPLy.audit_entries(server.state.audit_log)
                failures = filter(e -> e.success === false, entries)
                @test !isempty(failures)
                entry = failures[end]
                @test occursin("maximum size", something(entry.error, ""))
                @test entry.operation == ""
            finally
                isopen(client) && close(client)
            end
        finally
            close(server)
        end
    end

    @testset "rate limit enforced per connection" begin
        limits = REPLy.ResourceLimits(rate_limit_per_min=1)
        server = REPLy.serve(; port=0, limits=limits)
        try
            client = connect(REPLy.server_port(server))
            try
                send_request(client, Dict("op" => "eval", "id" => "rl1", "code" => "42"))
                first_msgs = collect_until_done(client)
                @test !("rate-limited" in last(first_msgs)["status"])
                send_request(client, Dict("op" => "eval", "id" => "rl2", "code" => "42"))
                second_msgs = collect_until_done(client)
                terminal = last(second_msgs)
                @test "rate-limited" in terminal["status"]
                @test terminal["err"] == "Rate limit exceeded"
            finally
                isopen(client) && close(client)
            end
        finally
            close(server)
        end
    end

    @testset "history entries bounded per session" begin
        manager = REPLy.SessionManager()
        limits = REPLy.ResourceLimits(max_history_entries=3)
        state = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        handler = REPLy.build_handler(manager=manager, state=state)
        handler(Dict("op" => "new-session", "id" => "h0", "name" => "hs"))
        for i in 1:5
            handler(Dict("op" => "eval", "id" => "h$i", "code" => string(i),
                "session" => "hs"))
        end
        session = only(values(manager.named_sessions))
        @test length(session.history) == 3
        @test session.history == [3, 4, 5]  # oldest two evicted
    end

    @testset "low rate limit triggers startup warning" begin
        logs = Test.TestLogger()
        server = with_logger(logs) do
            REPLy.serve(; port=0,
                limits=REPLy.ResourceLimits(rate_limit_per_min=1))
        end
        try
            warns = [string(m.message) for m in logs.logs if m.level == Logging.Warn]
            @test any(m -> occursin("rate_limit_per_min", m), warns)
        finally
            close(server)
        end
    end

    @testset "audit entry written per operation" begin
        server = REPLy.serve(; port=0)
        try
            client = connect(REPLy.server_port(server))
            try
                send_request(client, Dict("op" => "new-session", "id" => "au0",
                    "name" => "audit-op"))
                collect_until_done(client)
                send_request(client, Dict("op" => "eval", "id" => "au1",
                    "session" => "audit-op", "code" => "1+1"))
                collect_until_done(client)
            finally
                isopen(client) && close(client)
            end
            entries = REPLy.audit_entries(server.state.audit_log)
            e = only(filter(x -> x.operation == "eval", entries))
            @test e.success === true
            @test e.error === nothing
            @test e.timestamp isa DateTime
            @test e.client_id isa UUID
            @test e.session_id isa String   # named session → non-null session_id
            @test e.user isa String          # empty: no auth (spec allows "")
            @test e.source_ip isa String
        finally
            close(server)
        end
    end

    @testset "in-memory log bounded at 100k entries" begin
        @test REPLy.DEFAULT_AUDIT_MAX_ENTRIES == 100_000
        @test REPLy.DEFAULT_AUDIT_EVICT_COUNT == 50_000
        log = REPLy.AuditLog()
        for i in 1:(REPLy.DEFAULT_AUDIT_MAX_ENTRIES + 1)
            REPLy.record_audit!(log, REPLy.AuditLogEntry(
                timestamp=now(UTC), client_id=UUID(UInt128(0)),
                operation="op-$i", source_ip="", success=true))
        end
        entries = REPLy.audit_entries(log)
        # The 100_001st write triggers eviction of the oldest 50_000.
        @test length(entries) == REPLy.DEFAULT_AUDIT_EVICT_COUNT + 1
        @test length(entries) <= REPLy.DEFAULT_AUDIT_MAX_ENTRIES
        @test entries[1].operation == "op-50001"   # oldest 50k evicted
        @test entries[end].operation == "op-100001"
        # The bound holds under continued writes.
        for i in (REPLy.DEFAULT_AUDIT_MAX_ENTRIES + 2):(REPLy.DEFAULT_AUDIT_MAX_ENTRIES + 11)
            REPLy.record_audit!(log, REPLy.AuditLogEntry(
                timestamp=now(UTC), client_id=UUID(UInt128(0)),
                operation="op-$i", source_ip="", success=true))
        end
        @test length(REPLy.audit_entries(log)) == REPLy.DEFAULT_AUDIT_EVICT_COUNT + 11
    end

    @testset "log file rotated at 100 MB" begin
        @test REPLy.DEFAULT_AUDIT_ROTATE_BYTES == 100_000_000
        path = tempname()
        try
            # Behavioral half: rotation fires when the configured size limit is
            # crossed (the 100 MB constant itself is asserted above).
            log = REPLy.AuditLog(path=path, rotate_bytes=200)
            big_op = repeat("x", 300)
            REPLy.record_audit!(log, REPLy.AuditLogEntry(
                timestamp=now(UTC), client_id=UUID(UInt128(0)),
                operation=big_op * "-1", source_ip="", success=true))
            REPLy.record_audit!(log, REPLy.AuditLogEntry(
                timestamp=now(UTC), client_id=UUID(UInt128(0)),
                operation=big_op * "-2", source_ip="", success=true))
            @test isfile(path * ".1")
            rotated_lines = filter(!isempty, readlines(path * ".1"))
            @test length(rotated_lines) == 1
            @test occursin("-1", only(rotated_lines))
            fresh_lines = filter(!isempty, readlines(path))
            @test length(fresh_lines) == 1
            @test occursin("-2", only(fresh_lines))
        finally
            isfile(path) && rm(path; force=true)
            isfile(path * ".1") && rm(path * ".1"; force=true)
        end
    end

    @testset "disconnect cancels running eval" begin
        server = REPLy.serve(; port=0)
        try
            sock = connect(REPLy.server_port(server))
            try
                send_request(sock, Dict("op" => "eval", "id" => "dc1",
                    "code" => "while true; sleep(0.05); end"))
                @test timedwait(() ->
                    !isempty(REPLy.active_eval_tasks(server.state)), 5.0) === :ok
                close(sock)
                # BIZ-008: the eval task is interrupted instead of running
                # indefinitely and producing output to a closed channel.
                @test timedwait(() ->
                    isempty(REPLy.active_eval_tasks(server.state)), 5.0) === :ok
            finally
                isopen(sock) && close(sock)
            end
            # The server itself stays healthy after the disconnect.
            c2 = connect(REPLy.server_port(server))
            try
                send_request(c2, Dict("op" => "eval", "id" => "after", "code" => "1+1"))
                msgs = collect_until_done(c2)
                @test !isempty(msgs)
                @test "done" in last(filter(m -> haskey(m, "status"), msgs))["status"]
            finally
                isopen(c2) && close(c2)
            end
        finally
            close(server)
        end
    end

    @testset "concurrent evals do not leak output" begin
        server = REPLy.serve(; port=0)
        try
            c1 = connect(REPLy.server_port(server))
            c2 = connect(REPLy.server_port(server))
            try
                send_request(c1, Dict("op" => "eval", "id" => "m1",
                    "code" => "println(\"MARK-1\"); sleep(0.3)"))
                send_request(c2, Dict("op" => "eval", "id" => "m2",
                    "code" => "println(\"MARK-2\"); sleep(0.3)"))
                msgs1 = collect_until_done(c1; timeout_s=10.0)
                msgs2 = collect_until_done(c2; timeout_s=10.0)
                outs1 = join([m["out"] for m in msgs1 if haskey(m, "out")], "")
                outs2 = join([m["out"] for m in msgs2 if haskey(m, "out")], "")
                @test occursin("MARK-1", outs1)
                @test !occursin("MARK-2", outs1)
                @test occursin("MARK-2", outs2)
                @test !occursin("MARK-1", outs2)
            finally
                for c in (c1, c2)
                    isopen(c) && close(c)
                end
            end
        finally
            close(server)
        end
    end

    @testset "response silently discarded after disconnect" begin
        server = REPLy.serve(; port=0)
        try
            c1 = connect(REPLy.server_port(server))
            send_request(c1, Dict("op" => "eval", "id" => "r1",
                "code" => "for i in 1:5; println(i); sleep(0.1); end"))
            sleep(0.2)  # at least one out chunk has been streamed
            close(c1)   # disconnect while the eval is still producing output
            sleep(0.5)  # server must not crash (ARCH-002)
            c2 = connect(REPLy.server_port(server))
            try
                send_request(c2, Dict("op" => "eval", "id" => "r2", "code" => "1+1"))
                msgs = collect_until_done(c2)
                @test !isempty(msgs)
                @test "done" in last(filter(m -> haskey(m, "status"), msgs))["status"]
            finally
                isopen(c2) && close(c2)
            end
        finally
            close(server)
        end
    end

    @testset "shutdown interrupts in-flight evals" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "sd-eval")
        server = REPLy.serve(; port=0, manager=manager)
        try
            sock = connect(REPLy.server_port(server))
            try
                send_request(sock, Dict("op" => "eval", "id" => "sd1",
                    "session" => "sd-eval", "code" => "while true; sleep(0.05); end"))
                @test timedwait(() ->
                    REPLy.session_state(session) == REPLy.SessionRunning, 5.0) === :ok
                # Shutdown initiated from a second connection (the first is
                # blocked serving the long-running eval).
                c2 = connect(REPLy.server_port(server))
                send_request(c2, Dict("op" => "shutdown", "id" => "sd-op"))
                collect_until_done(c2; timeout_s=5.0)
                isopen(c2) && close(c2)
                @test timedwait(() -> server.state.shutdown_requested[], 5.0) === :ok
                # In-flight eval receives InterruptException; server exits
                # cleanly within the grace period.
                @test timedwait(() ->
                    isempty(REPLy.active_eval_tasks(server.state)), 8.0) === :ok
                @test timedwait(() -> !isopen(server.listener), 8.0) === :ok
                @test REPLy.session_state(session) == REPLy.SessionIdle
            finally
                isopen(sock) && close(sock)
            end
        finally
            close(server)
        end
    end

    @testset "shutdown completes within grace period" begin
        server = REPLy.serve(; port=0)
        sock = connect(REPLy.server_port(server))
        try
            send_request(sock, Dict("op" => "eval", "id" => "g1", "code" => "sleep(0.2)"))
            # Reader waits for EOF: graceful shutdown flushes pending sends
            # (value + done) and then closes the client connection.
            eof_ch = Channel{Int}(1)
            reader = @async begin
                lines = 0
                while !eof(sock)
                    readline(sock)
                    lines += 1
                end
                put!(eof_ch, lines)
            end
            elapsed = @elapsed close(server; grace_seconds=5.0)
            @test elapsed < 5.0
            @test !isopen(server.listener)
            @test timedwait(() -> isready(eof_ch), 2.0) === :ok
            @test take!(eof_ch) >= 1
            wait(reader)
        finally
            isopen(sock) && close(sock)
        end
    end

    @testset "shutdown proceeds after grace period expires" begin
        entered = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        server = REPLy.serve(; port=0, middleware=REPLy.AbstractMiddleware[
            GraceExpiryProbe(entered, release), REPLy.UnknownOpMiddleware()])
        sock = connect(REPLy.server_port(server))
        try
            send_request(sock, Dict("op" => "grace-expire", "id" => "x1"))
            take!(entered)
            # An eval that never terminates within the grace period does not
            # block shutdown: the server closes anyway.
            elapsed = @elapsed close(server; grace_seconds=0.2)
            @test 0.15 <= elapsed < 2.0
            @test !isopen(sock) || eof(sock)
        finally
            put!(release, nothing)
            isopen(sock) && close(sock)
            @test timedwait(() -> REPLy.active_request_count(server.state) == 0, 1.0) === :ok
        end
    end

end