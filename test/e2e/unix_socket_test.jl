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

    @testset "stale socket is unlinked and replaced at listen" begin
        # Fabricate a demonstrably stale socket file: a bound-and-listening
        # socket is renamed away, then its listener is closed. The rename leaves
        # the socket inode at `stale`; the close unlinks the original path, so
        # nothing listens behind `stale` and its fd is gone.
        stale = tempname()
        holder = tempname()
        lsn = listen(holder)
        mv(holder, stale)
        close(lsn)
        @test ispath(stale) && issocket(stale)

        with_unix_server(path=stale) do handle
            @test handle.path == stale
            @test ispath(stale)
            @test issocket(stale)

            sock = connect(stale)
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

    @testset "live socket is never hijacked" begin
        live = tempname()
        lsn = listen(live)
        @test issocket(live)

        err = try
            REPLy.listen_unix(live)
            nothing
        catch e
            e
        end
        @test err isa Base.IOError
        @test occursin(live, sprint(showerror, err))

        # The existing listener is untouched and still accepts connections.
        @test ispath(live) && issocket(live)
        sock = connect(live)
        close(sock)

        close(lsn)
    end

    @testset "ordinary file at socket path is refused" begin
        path = tempname()
        write(path, "precious contents")
        contents = read(path)
        @test isfile(path)

        err = try
            REPLy.listen_unix(path)
            nothing
        catch e
            e
        end
        @test err isa Base.IOError
        @test occursin(path, sprint(showerror, err))

        # The file is byte-identical — never deleted or replaced.
        @test isfile(path)
        @test read(path) == contents

        rm(path; force=true)
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
