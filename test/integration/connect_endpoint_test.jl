# Purpose: Verify checked endpoint discovery and application ownership for tool builders.
# Responsibilities:
# - Exercise TCP/Unix discovery, legacy metadata, malformed peers and deadlines.
# - Prove discovery does not change namespace trust or own application shutdown.
# Rationale: REPLy_jl-q8dz.2 requires bounded opt-in discovery while keeping Client compatible.
using Test, REPLy, Sockets, JSON3

close_discovery_peer(socket) = socket[] === nothing ? nothing : close(socket[])
function rethrow_peer_error(ex)
    ex isa Base.IOError || ex isa EOFError || throw(ex)
end

function serve_discovery_peer(peer, respond)
    (; listener, socket) = peer
    try
        socket[] = accept(listener)
        request = JSON3.read(readline(socket[]))
        respond(socket[], request)
    catch ex
        rethrow_peer_error(ex)
    finally
        close_discovery_peer(socket)
    end
end

function with_discovery_peer(f, respond)
    listener = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(listener)[2])
    socket = Ref{Union{Nothing, TCPSocket}}(nothing)
    task = @async serve_discovery_peer((; listener, socket), respond)
    try
        f(port)
    finally
        close(listener)
        timedwait(() -> istaskdone(task), 0.5)
        close_discovery_peer(socket)
        wait(task)
    end
end

legacy_describe(id) = Dict("id" => id, "ops" => Dict(), "versions" => Dict("reply" => "0.3"),
    "encodings-available" => ["json"], "encoding-current" => "json", "status" => ["done"])

@testset "checked endpoint discovery" begin
    @testset "prepared application survives disconnect; namespace trust stays explicit" begin
        for unix in (false, true)
            unix && Sys.iswindows() && continue
            manager = REPLy.SessionManager()
            REPLy.create_named_session!(manager, "host"; trusted=true)
            server = unix ? REPLy.serve(; manager, socket_path=tempname()) : REPLy.serve(; manager, port=0)
            try
                # First-use server compilation is outside the warm latency cases below.
                client = unix ? REPLy.connect_endpoint(server_socket_path(server); connect_timeout_s=30) :
                    REPLy.connect_endpoint("127.0.0.1", server_port(server); connect_timeout_s=30)
                try
                    @test client.capabilities["execution-mode"] == "attached"
                    @test client.capabilities["timeout-enforcement"] == "cooperative"
                    @test client.capabilities["memory-enforcement"] == "unsupported"
                    @test client.capabilities["effective-memory-limit-mb"] == 0
                    send!(client, Dict("op" => "eval", "id" => "eval", "code" => "nameof(@__MODULE__)"))
                    replies = REPLy.collect_until_done(client, "eval")
                    @test only(filter(m -> haskey(m, "value"), replies))["value"] != ":Main"
                    send!(client, Dict("op" => "eval", "id" => "host", "session" => "host",
                        "code" => "nameof(@__MODULE__)"))
                    replies = REPLy.collect_until_done(client, "host")
                    @test only(filter(m -> haskey(m, "value"), replies))["value"] == ":Main"
                finally
                    disconnect(client)
                end
                # Constructors retain ordinary connections without mandatory discovery.
                again = unix ? Client(server_socket_path(server)) : Client("127.0.0.1", server_port(server))
                try
                    send!(again, Dict("op" => "ping", "id" => "alive"))
                    @test "done" in last(REPLy.collect_until_done(again, "alive"))["status"]
                finally
                    disconnect(again)
                end
            finally
                close(server)
            end
        end
    end

    @testset "unprepared endpoints fail without launching" begin
        listener = listen(ip"127.0.0.1", 0)
        port = Int(getsockname(listener)[2])
        close(listener)
        @test_throws Exception REPLy.connect_endpoint("127.0.0.1", port)
        if !Sys.iswindows()
            @test_throws Exception REPLy.connect_endpoint(tempname())
        end
    end

    @testset "valid legacy discovery has unknown guarantees" begin
        with_discovery_peer((port) -> begin
            c = REPLy.connect_endpoint("127.0.0.1", port)
            try
                @test c.capabilities["execution-mode"] == "unknown"
                @test c.capabilities["timeout-enforcement"] == "unknown"
                @test c.capabilities["memory-enforcement"] == "unknown"
            finally
                disconnect(c)
            end
        end, (sock, req) -> write(sock, JSON3.write(legacy_describe(req.id)), '\n'))
    end

    @testset "invalid discovery closes attempted connection" begin
        for mutate in (
            m -> Dict("id" => m["id"], "status" => ["done"]),
            m -> merge(m, Dict("id" => "wrong-id")),
            m -> merge(m, Dict("encoding-current" => "binary")),
            m -> merge(m, Dict("ops" => [])),
            m -> merge(m, Dict("status" => ["done", "error"])),
            m -> merge(m, Dict("status" => "done")),
            m -> merge(m, Dict("timeout-enforcement" => "guaranteed")),
            m -> merge(m, Dict("effective-memory-limit-mb" => true)),
        )
            closed = Ref(false)
            with_discovery_peer((port) -> begin
                @test_throws Exception REPLy.connect_endpoint("127.0.0.1", port; connect_timeout_s=1)
            end, (sock, req) -> begin
                write(sock, JSON3.write(mutate(legacy_describe(req.id))), '\n'); flush(sock)
                closed[] = eof(sock)
            end)
            @test closed[]
        end
        with_discovery_peer(port -> (@test_throws Exception REPLy.connect_endpoint("127.0.0.1", port)),
            (sock, req) -> nothing)
        with_discovery_peer(port -> (@test_throws Exception REPLy.connect_endpoint("127.0.0.1", port)),
            (sock, req) -> write(sock, "garbage\n"))
    end

    @testset "silent peer times out and closes" begin
        closed = Ref(false)
        with_discovery_peer((port) -> begin
            started = time_ns()
            @test_throws Exception REPLy.connect_endpoint("127.0.0.1", port; connect_timeout_s=0.1)
            @test (time_ns() - started) / 1e9 < 0.5
        end, (sock, req) -> (closed[] = eof(sock)))
        @test closed[]
    end

    @testset "DNS and discovery use the same deadline" begin
        resolver_finished = Ref(false)
        listener = listen(ip"127.0.0.1", 0)
        try
            port = Int(getsockname(listener)[2])
            @test_throws Exception REPLy._connect_tcp_endpoint("delayed.test", port;
                connect_timeout_s=0.05, resolver=host -> begin
                    sleep(0.15); resolver_finished[] = true; [ip"127.0.0.1"]
                end)
            @test timedwait(() -> resolver_finished[], 1) == :ok
            # A late resolver result must not revive the closed attempt.
            accepted = @async try accept(listener) catch; nothing end
            @test timedwait(() -> istaskdone(accepted), 0.05) == :timed_out
            close(listener); wait(accepted)
        finally
            close(listener)
        end
        delayed_resolver = host -> (sleep(0.1); [ip"127.0.0.1"])
        # Compile this resolver/connection specialization before measuring its budget.
        @test_throws Exception REPLy._connect_tcp_endpoint("delayed.test", 1;
            connect_timeout_s=1, resolver=delayed_resolver)
        with_discovery_peer(port -> begin
            started = time_ns()
            caught = try
                REPLy._connect_tcp_endpoint("delayed.test", port;
                connect_timeout_s=0.15, resolver=delayed_resolver)
                nothing
            catch ex
                ex
            end
            elapsed = (time_ns() - started) / 1e9
            @test caught isa Exception
            @test elapsed < 0.23
        end, (sock, req) -> begin
            sleep(0.1)
            isopen(sock) && write(sock, JSON3.write(legacy_describe(req.id)), '\n')
        end)
    end

    @testset "invalid budgets fail before connecting" begin
        for budget in (0, -1, Inf, NaN)
            @test_throws ArgumentError REPLy.connect_endpoint("127.0.0.1", 1; connect_timeout_s=budget)
        end
    end
end
