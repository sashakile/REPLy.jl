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
end
