@testset "e2e: eval over unix socket" begin
    @testset "single client receives value then done" begin
        with_unix_server() do handle
            sock = connect(handle.path)

            try
                send_request(sock, Dict(
                    "op" => "eval",
                    "id" => "unix-1",
                    "code" => "1 + 1",
                ))

                msgs = collect_until_done(sock)
                assert_conformance(msgs, "unix-1")
                @test any(get(msg, "value", nothing) == "2" for msg in msgs)
            finally
                close(sock)
            end
        end
    end

    @testset "socket file is owner-only" begin
        with_unix_server() do handle
            @test ispath(handle.path)
            @test stat(handle.path).mode & 0o777 == 0o600
        end
    end

    @testset "stale socket path is removed before listen" begin
        path = tempname()
        write(path, "stale")
        @test isfile(path)

        with_unix_server(path=path) do handle
            @test handle.path == path
            @test ispath(handle.path)
            @test !isfile(handle.path)

            sock = connect(handle.path)
            try
                send_request(sock, Dict(
                    "op" => "eval",
                    "id" => "unix-stale",
                    "code" => "40 + 2",
                ))

                msgs = collect_until_done(sock)
                assert_conformance(msgs, "unix-stale")
                @test any(get(msg, "value", nothing) == "42" for msg in msgs)
            finally
                close(sock)
            end
        end
    end

    @testset "socket path is removed on server close" begin
        path = tempname()
        server = REPLy.serve(; socket_path=path)
        @test ispath(path)

        close(server)
        @test !ispath(path)
    end

    @testset "unix socket mode rejects mixed tcp arguments" begin
        path = tempname()
        @test_throws ArgumentError REPLy.serve(; socket_path=path, port=6000)
        @test_throws ArgumentError REPLy.serve(; socket_path=path, host=ip"127.0.0.2")
        @test !ispath(path)
    end
end
