@testset "Disconnect cleanup and closed-channel response resilience" begin

    @testset "post-disconnect response discard — handle_client! returns cleanly" begin
        # Server: accept a connection, handle a message, but client disconnects before response.
        # The server should NOT crash — is_connection_closed silently discards.
        listener = listen(ip"127.0.0.1", 0)
        port = Int(getsockname(listener)[2])

        done_ch    = Channel{Bool}(1)
        crashed_ch = Channel{Bool}(1)

        server_task = @async begin
            socket = accept(listener)
            close(listener)
            try
                REPLy.handle_client!(socket, msg -> begin
                    sleep(0.05)  # yield so client can disconnect first
                    [REPLy.done_response(String(get(msg, "id", "")))]
                end)
                put!(done_ch, true)
            catch ex
                put!(crashed_ch, true)
            end
        end

        client = connect(port)
        send_request(client, Dict("op" => "eval", "id" => "dc1", "code" => "1"))
        sleep(0.01)
        close(client)  # disconnect before response arrives

        result = timedwait(() -> isready(done_ch) || isready(crashed_ch), 5.0)
        @test result === :ok
        @test isready(done_ch) && !isready(crashed_ch)
        wait(server_task)
    end

    @testset "ephemeral session cleaned up after client disconnect" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        @test REPLy.session_count(manager) == 0

        listener = listen(ip"127.0.0.1", 0)
        port = Int(getsockname(listener)[2])

        server_task = @async begin
            socket = accept(listener)
            close(listener)
            REPLy.handle_client!(socket, handler)
        end

        client = connect(port)
        # Send an eval (creates ephemeral session) then immediately close.
        send_request(client, Dict("op" => "eval", "id" => "eph1", "code" => "1+1"))
        sleep(0.01)
        close(client)

        wait(server_task)
        # After handle_client! returns, the ephemeral session must be cleaned up.
        @test REPLy.session_count(manager) == 0
    end

    @testset "named session persists after client disconnects" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "persist-test")  # must exist before routing
        handler = REPLy.build_handler(; manager=manager)

        listener = listen(ip"127.0.0.1", 0)
        port = Int(getsockname(listener)[2])

        # First connection: use named session to bind a variable.
        server_task1 = @async begin
            socket = accept(listener)
            REPLy.handle_client!(socket, handler)
        end

        client1 = connect(port)
        send_request(client1, Dict("op" => "eval", "id" => "ns1", "code" => "x = 42", "session" => "persist-test"))
        collect_until_done(client1)
        close(client1)   # disconnect
        wait(server_task1)

        # Named session should still exist.
        @test !isnothing(REPLy.lookup_named_session(manager, "persist-test"))

        # Second connection: access same named session.
        server_task2 = @async begin
            socket = accept(listener)
            REPLy.handle_client!(socket, handler)
        end

        client2 = connect(port)
        send_request(client2, Dict("op" => "eval", "id" => "ns2", "code" => "x", "session" => "persist-test"))
        msgs2 = collect_until_done(client2)
        close(client2)
        wait(server_task2)
        close(listener)

        # x should still be 42 from first connection.
        value_msg = first(filter(m -> haskey(m, "value"), msgs2))
        @test occursin("42", value_msg["value"])
    end

    @testset "TCPServerHandle/UnixServerHandle have a clients_lock field (qr9)" begin
        server = REPLy.serve(; port=0)
        try
            @test hasproperty(server, :clients_lock)
            @test server.clients_lock isa ReentrantLock
        finally
            close(server)
        end
    end

    @testset "clients and client_tasks are empty after N concurrent disconnects (qr9)" begin
        server = REPLy.serve(; port=0)
        port = REPLy.server_port(server)
        try
            N = 5
            sockets = [connect(ip"127.0.0.1", port) for _ in 1:N]
            sleep(0.1)
            @test length(server.clients) == N
            @test length(server.client_tasks) == N

            for s in sockets; close(s); end
            sleep(0.2)

            @test isempty(server.clients)
            @test isempty(server.client_tasks)
        finally
            close(server)
        end
    end

    @testset "multiple rapid disconnects do not leak sessions" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager)

        listener = listen(ip"127.0.0.1", 0)
        port = Int(getsockname(listener)[2])

        # Spawn 3 server tasks.
        tasks = [@async begin
            socket = accept(listener)
            REPLy.handle_client!(socket, handler)
        end for _ in 1:3]

        for i in 1:3
            client = connect(port)
            send_request(client, Dict("op" => "eval", "id" => "multi$i", "code" => "1"))
            close(client)
        end

        for t in tasks
            wait(t)
        end
        close(listener)

        @test REPLy.session_count(manager) == 0
    end

end
