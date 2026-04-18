@testset "e2e: eval over tcp" begin
    @testset "single client receives value then done" begin
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

    @testset "two concurrent clients each receive a done-terminated stream" begin
        with_server(port=0) do handle
            first = connect(handle.port)
            second = connect(handle.port)

            try
                send_request(first, Dict("op" => "eval", "id" => "e2e-a", "code" => "10 + 1"))
                send_request(second, Dict("op" => "eval", "id" => "e2e-b", "code" => "20 + 2"))

                first_task = @async collect_until_done(first)
                second_task = @async collect_until_done(second)

                first_msgs = fetch(first_task)
                second_msgs = fetch(second_task)

                assert_conformance(first_msgs, "e2e-a")
                assert_conformance(second_msgs, "e2e-b")
                @test any(get(msg, "value", nothing) == "11" for msg in first_msgs)
                @test any(get(msg, "value", nothing) == "22" for msg in second_msgs)
            finally
                close(first)
                close(second)
            end
        end
    end

    @testset "server survives a client disconnect during eval" begin
        with_server(port=0) do handle
            disconnected = connect(handle.port)
            survivor = connect(handle.port)

            try
                send_request(disconnected, Dict(
                    "op" => "eval",
                    "id" => "e2e-drop",
                    "code" => "sleep(0.2); 40 + 2",
                ))
                close(disconnected)

                send_request(survivor, Dict(
                    "op" => "eval",
                    "id" => "e2e-survivor",
                    "code" => "1 + 2",
                ))

                msgs = collect_until_done(survivor)
                assert_conformance(msgs, "e2e-survivor")
                @test any(get(msg, "value", nothing) == "3" for msg in msgs)
            finally
                isopen(disconnected) && close(disconnected)
                close(survivor)
            end
        end
    end
end
