@testset "e2e: multi-listener server" begin
    @testset "TCP and Unix socket share session namespace" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "shared")
        server = REPLy.serve_multi((; port=0), (; socket_path=tempname()); manager=manager)
        tcp_port = REPLy.server_port(server.listeners[1])
        unix_path = REPLy.server_socket_path(server.listeners[2])
        try
            tcp = connect(tcp_port)
            unix_sock = connect(unix_path)
            try
                # Define a variable in the shared session over TCP
                send_request(tcp, Dict("op" => "eval", "id" => "ml-ns-1", "session" => "shared", "code" => "ml_x = 99 + 1"))
                tcp_msgs = collect_until_done(tcp)
                assert_conformance(tcp_msgs, "ml-ns-1")
                @test any(get(msg, "value", nothing) == "100" for msg in tcp_msgs)

                # Read the variable back over Unix socket (same session namespace)
                send_request(unix_sock, Dict("op" => "eval", "id" => "ml-ns-2", "session" => "shared", "code" => "ml_x"))
                unix_msgs = collect_until_done(unix_sock)
                assert_conformance(unix_msgs, "ml-ns-2")
                @test any(get(msg, "value", nothing) == "100" for msg in unix_msgs)
            finally
                close(tcp)
                close(unix_sock)
            end
        finally
            close(server)
        end
    end

    @testset "close removes Unix socket path and stops TCP port" begin
        path = tempname()
        server = REPLy.serve_multi((; port=0), (; socket_path=path))
        @test server isa REPLy.MultiListenerServer
        tcp_port = REPLy.server_port(server.listeners[1])
        @test ispath(path)

        close(server)
        @test !ispath(path)
        @test_throws Exception connect(ip"127.0.0.1", tcp_port)
    end

    @testset "single TCP spec works" begin
        server = REPLy.serve_multi((; port=0))
        @test server isa REPLy.MultiListenerServer
        @test length(server.listeners) == 1
        close(server)
    end

    @testset "empty specs throws" begin
        @test_throws ArgumentError REPLy.serve_multi()
    end

    @testset "session limit enforced globally across TCP and Unix listeners" begin
        limits  = REPLy.ResourceLimits(max_sessions=1)
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "occupied")

        with_multi_server(; limits=limits, manager=manager) do handle
            tcp       = connect(handle.tcp_port)
            unix_sock = connect(handle.unix_path)
            try
                send_request(tcp, Dict("op" => "eval", "id" => "ml-lim-tcp", "code" => "1+1"))
                tcp_msgs = collect_until_done(tcp)
                @test "session-limit-reached" in last(tcp_msgs)["status"]
                @test "error"                 in last(tcp_msgs)["status"]

                send_request(unix_sock, Dict("op" => "eval", "id" => "ml-lim-unix", "code" => "2+2"))
                unix_msgs = collect_until_done(unix_sock)
                @test "session-limit-reached" in last(unix_msgs)["status"]
                @test "error"                 in last(unix_msgs)["status"]
            finally
                close(tcp)
                close(unix_sock)
            end
        end
    end

    @testset "concurrent eval limit enforced globally across TCP and Unix listeners" begin
        limits = REPLy.ResourceLimits(max_concurrent_evals=0)

        with_multi_server(; limits=limits) do handle
            tcp       = connect(handle.tcp_port)
            unix_sock = connect(handle.unix_path)
            try
                send_request(tcp, Dict("op" => "eval", "id" => "ml-ce-tcp", "code" => "1+1"))
                tcp_msgs = collect_until_done(tcp)
                @test "concurrency-limit-reached" in last(tcp_msgs)["status"]
                @test "error"                     in last(tcp_msgs)["status"]

                send_request(unix_sock, Dict("op" => "eval", "id" => "ml-ce-unix", "code" => "2+2"))
                unix_msgs = collect_until_done(unix_sock)
                @test "concurrency-limit-reached" in last(unix_msgs)["status"]
                @test "error"                     in last(unix_msgs)["status"]
            finally
                close(tcp)
                close(unix_sock)
            end
        end
    end

    @testset "ephemeral sessions are isolated across listeners" begin
        with_multi_server() do handle
            tcp       = connect(handle.tcp_port)
            unix_sock = connect(handle.unix_path)
            try
                # Assign in TCP ephemeral session (fresh module per eval)
                send_request(tcp, Dict("op" => "eval", "id" => "ml-eph-1", "code" => "ml_isolation_x = 555"))
                tcp_msgs = collect_until_done(tcp)
                assert_conformance(tcp_msgs, "ml-eph-1")
                @test any(get(msg, "value", nothing) == "555" for msg in tcp_msgs)

                # Unix ephemeral session is a separate fresh module — variable not defined
                send_request(unix_sock, Dict("op" => "eval", "id" => "ml-eph-2", "code" => "ml_isolation_x"))
                unix_msgs = collect_until_done(unix_sock)
                @test "error" in last(unix_msgs)["status"]
            finally
                close(tcp)
                close(unix_sock)
            end
        end
    end

    @testset "concurrent evals on TCP and Unix complete successfully" begin
        with_multi_server() do handle
            tcp       = connect(handle.tcp_port)
            unix_sock = connect(handle.unix_path)
            try
                send_request(tcp,       Dict("op" => "eval", "id" => "ml-conc-tcp",  "code" => "11 * 11"))
                send_request(unix_sock, Dict("op" => "eval", "id" => "ml-conc-unix", "code" => "7 * 7"))

                tcp_task  = @async collect_until_done(tcp)
                unix_task = @async collect_until_done(unix_sock)

                tcp_msgs  = fetch(tcp_task)
                unix_msgs = fetch(unix_task)

                assert_conformance(tcp_msgs,  "ml-conc-tcp")
                assert_conformance(unix_msgs, "ml-conc-unix")
                @test any(get(msg, "value", nothing) == "121" for msg in tcp_msgs)
                @test any(get(msg, "value", nothing) == "49"  for msg in unix_msgs)
            finally
                close(tcp)
                close(unix_sock)
            end
        end
    end
end
