@testset "e2e: eval over tcp" begin
    with_server(port=0) do handle
        sock = connect(handle.port)

        try
            send_request(sock, Dict(
                "op" => "eval",
                "id" => "e2e-1",
                "code" => "1 + 1",
            ))

            msgs = collect_until_done(sock)
            assert_conformance(msgs, "e2e-1")
            @test any(get(msg, "value", nothing) == "2" for msg in msgs)
        finally
            close(sock)
        end
    end
end
