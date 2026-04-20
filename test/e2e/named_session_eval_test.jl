@testset "e2e: named session eval persistence over tcp" begin
    @testset "repeated evals against same named session persist bindings" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "tcp-persist")
        server = REPLy.serve(; port=0, manager=manager)
        port = REPLy.server_port(server)

        try
            sock = connect(port)
            try
                # First eval: define a variable
                send_request(sock, Dict(
                    "op" => "eval",
                    "id" => "e2e-ns-1",
                    "code" => "counter = 0",
                    "session" => "tcp-persist",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "e2e-ns-1")
                @test any(get(m, "value", nothing) == "0" for m in msgs)

                # Second eval: increment the variable
                send_request(sock, Dict(
                    "op" => "eval",
                    "id" => "e2e-ns-2",
                    "code" => "counter += 1; counter",
                    "session" => "tcp-persist",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "e2e-ns-2")
                @test any(get(m, "value", nothing) == "1" for m in msgs)

                # Third eval: increment again
                send_request(sock, Dict(
                    "op" => "eval",
                    "id" => "e2e-ns-3",
                    "code" => "counter += 1; counter",
                    "session" => "tcp-persist",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "e2e-ns-3")
                @test any(get(m, "value", nothing) == "2" for m in msgs)
            finally
                close(sock)
            end
        finally
            close(server)
        end
    end

    @testset "named session persistence works across different client connections" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "cross-conn")
        server = REPLy.serve(; port=0, manager=manager)
        port = REPLy.server_port(server)

        try
            # First connection: define a variable
            sock1 = connect(port)
            try
                send_request(sock1, Dict(
                    "op" => "eval",
                    "id" => "e2e-xc-1",
                    "code" => "shared_val = 42",
                    "session" => "cross-conn",
                ))
                msgs = collect_until_done(sock1)
                assert_conformance(msgs, "e2e-xc-1")
                @test any(get(m, "value", nothing) == "42" for m in msgs)
            finally
                close(sock1)
            end

            # Second connection: read the same variable
            sock2 = connect(port)
            try
                send_request(sock2, Dict(
                    "op" => "eval",
                    "id" => "e2e-xc-2",
                    "code" => "shared_val",
                    "session" => "cross-conn",
                ))
                msgs = collect_until_done(sock2)
                assert_conformance(msgs, "e2e-xc-2")
                @test any(get(m, "value", nothing) == "42" for m in msgs)
            finally
                close(sock2)
            end
        finally
            close(server)
        end
    end

    @testset "named session eval does not leak into ephemeral evals" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "no-leak")
        server = REPLy.serve(; port=0, manager=manager)
        port = REPLy.server_port(server)

        try
            sock = connect(port)
            try
                # Define in named session
                send_request(sock, Dict(
                    "op" => "eval",
                    "id" => "e2e-nl-1",
                    "code" => "secret_token = \"abc123\"",
                    "session" => "no-leak",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "e2e-nl-1")

                # Ephemeral eval (no session key) should NOT see it
                send_request(sock, Dict(
                    "op" => "eval",
                    "id" => "e2e-nl-2",
                    "code" => "secret_token",
                ))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "e2e-nl-2")
                # Should be an error response
                terminal = filter(m -> haskey(m, "status"), msgs)
                @test "error" in terminal[end]["status"]
            finally
                close(sock)
            end
        finally
            close(server)
        end
    end
end
