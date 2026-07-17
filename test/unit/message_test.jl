using JSON3

@testset "message transport" begin
    @testset "framing and receive postconditions" begin
        @testset "send! serializes newline-delimited JSON" begin
            io = IOBuffer()
            transport = REPLy.JSONTransport(io, ReentrantLock())

            REPLy.send!(transport, Dict("id" => "1", "status" => ["done"]))

            written = String(take!(io))
            @test endswith(written, "\n")
            @test JSON3.read(chomp(written), Dict{String, Any}) == Dict("id" => "1", "status" => Any["done"])
        end

        @testset "receive returns parsed flat object" begin
            transport = REPLy.JSONTransport(IOBuffer("{\"op\":\"eval\",\"id\":\"1\",\"code\":\"1+1\"}\n"), ReentrantLock())
            result = REPLy.receive(transport)
            @test get(result, "op", nothing) == "eval"
            @test get(result, "id", nothing) == "1"
            @test get(result, "code", nothing) == "1+1"
        end

        @testset "receive returns JSON3.Object without Dict allocation" begin
            transport = REPLy.JSONTransport(IOBuffer("{\"op\":\"eval\",\"id\":\"1\",\"code\":\"1+1\"}\n"), ReentrantLock())
            result = REPLy.receive(transport)
            @test !(result isa Dict{String, Any})
            @test result isa JSON3.Object
        end

        @testset "receive skips blank and whitespace lines" begin
            transport = REPLy.JSONTransport(IOBuffer("\n   \n{\"op\":\"eval\",\"id\":\"1\",\"code\":\"1+1\"}\n"), ReentrantLock())
            result = REPLy.receive(transport)
            @test get(result, "op", nothing) == "eval"
            @test get(result, "id", nothing) == "1"
        end

        @testset "receive treats malformed JSON as a closed boundary" begin
            transport = REPLy.JSONTransport(IOBuffer("{\"op\":\"eval\",\"id\":}\n"), ReentrantLock())
            @test isnothing(REPLy.receive(transport))
            @test isnothing(REPLy.receive(transport))
        end

        @testset "receive returns nothing on partial reads and disconnects" begin
            partial_transport = REPLy.JSONTransport(IOBuffer("{\"op\":\"eval\""), ReentrantLock())
            empty_transport = REPLy.JSONTransport(IOBuffer(""), ReentrantLock())

            @test isnothing(REPLy.receive(partial_transport))
            @test isnothing(REPLy.receive(empty_transport))
        end

        @testset "receive skips non-object JSON values" begin
            transport = REPLy.JSONTransport(IOBuffer("[]\n{\"op\":\"eval\",\"id\":\"1\",\"code\":\"1+1\"}\n"), ReentrantLock())
            result = REPLy.receive(transport)
            @test get(result, "op", nothing) == "eval"
            @test get(result, "id", nothing) == "1"
        end

        @testset "receive throws MessageTooLargeError when line exceeds max_message_bytes" begin
            line = "{\"op\":\"eval\",\"id\":\"1\",\"code\":\"" * repeat("x", 100) * "\"}\n"
            transport = REPLy.JSONTransport(IOBuffer(line), ReentrantLock())
            @test_throws REPLy.MessageTooLargeError REPLy.receive(transport; max_message_bytes=50)
        end

        @testset "receive accepts messages exactly at the byte limit" begin
            line = "{\"op\":\"eval\",\"id\":\"1\",\"code\":\"1+1\"}\n"
            transport = REPLy.JSONTransport(IOBuffer(line), ReentrantLock())
            @test !isnothing(REPLy.receive(transport; max_message_bytes=ncodeunits(chomp(line))))
        end

        @testset "read_bounded_line returns correct string up to newline" begin
            io = IOBuffer("hello\nworld\n")
            @test REPLy.read_bounded_line(io, 100) == "hello"
            @test REPLy.read_bounded_line(io, 100) == "world"
        end

        @testset "read_bounded_line throws MessageTooLargeError before reading full line" begin
            io = IOBuffer(repeat("x", 200) * "\n")
            @test_throws REPLy.MessageTooLargeError REPLy.read_bounded_line(io, 50)
        end

        @testset "read_bounded_line returns empty string for blank line" begin
            io = IOBuffer("\nhello\n")
            @test REPLy.read_bounded_line(io, 100) == ""
        end

        @testset "handle_client! sends error and disconnects on oversized message" begin
            listener = listen(ip"127.0.0.1", 0)
            port = Int(getsockname(listener)[2])
            server_task = @async begin
                socket = accept(listener)
                try
                    REPLy.handle_client!(socket, (_, _) -> [REPLy.done_response("1")]; max_message_bytes=50)
                finally
                    close(listener)
                end
            end

            client = connect(port)
            try
                big_payload = Dict("id" => "1", "op" => "eval", "code" => repeat("x", 200))
                send_request(client, big_payload)
                msgs = collect_until_done(client)

                @test length(msgs) == 1
                @test "done" in msgs[1]["status"]
                @test "error" in msgs[1]["status"]
                @test msgs[1]["err"] == "message exceeds maximum size of 50 bytes"
            finally
                isopen(client) && close(client)
                wait(server_task)
            end
        end

        @testset "handle_client! recovers from handler exceptions and returns error response" begin
            listener = listen(ip"127.0.0.1", 0)
            port = Int(getsockname(listener)[2])
            server_task = @async begin
                socket = accept(listener)
                try
                    REPLy.handle_client!(socket, (_, _) -> error("transport boom"))
                finally
                    close(listener)
                end
            end

            client = connect(port)
            try
                send_request(client, Dict("id" => 123, "op" => "eval", "code" => "1 + 1"))
                msgs = collect_until_done(client)

                @test length(msgs) == 1
                @test occursin("Internal server error", only(msgs)["err"])
                @test haskey(only(msgs), "correlation-id")
                @test !haskey(only(msgs), "ex")

                # Second request also works — connection stays open
                send_request(client, Dict("id" => "e2", "op" => "eval", "code" => "2 + 2"))
                second_msgs = collect_until_done(client)

                @test length(second_msgs) == 1
                @test occursin("Internal server error", only(second_msgs)["err"])
                @test haskey(only(second_msgs), "correlation-id")
                @test !haskey(only(second_msgs), "ex")
            finally
                isopen(client) && close(client)
                wait(server_task)
            end
        end
    end
end

@testset "message validation and response helpers" begin
    @testset "oversized ids are rejected with protocol error" begin
        request = Dict("op" => "eval", "id" => repeat("x", 257), "code" => "1+1")
        response = REPLy.validate_request(request)

        @test response == Dict(
            "id" => repeat("x", 257),
            "status" => ["done", "error"],
            "err" => "id exceeds maximum length of 256",
        )
        assert_conformance([response], request["id"])
    end

    @testset "empty ids are rejected" begin
        response = REPLy.validate_request(Dict("op" => "eval", "id" => "", "code" => "1+1"))
        @test response == Dict("id" => "", "status" => ["done", "error"], "err" => "id must not be empty")
    end

    @testset "non-string ids are rejected" begin
        response = REPLy.validate_request(Dict("op" => "eval", "id" => 123, "code" => "1+1"))
        @test response == Dict("id" => "", "status" => ["done", "error"], "err" => "id must be a string")
    end

    @testset "missing op is rejected" begin
        response = REPLy.validate_request(Dict("id" => "ok", "code" => "1+1"))
        @test response == Dict("id" => "ok", "status" => ["done", "error"], "err" => "op is required")
    end

    @testset "non-string op is rejected" begin
        response = REPLy.validate_request(Dict("op" => 123, "id" => "ok", "code" => "1+1"))
        @test response == Dict("id" => "ok", "status" => ["done", "error"], "err" => "op must be a string")
    end

    @testset "snake_case request keys are rejected" begin
        response = REPLy.validate_request(Dict("op" => "eval", "id" => "ok", "store_history" => true))
        @test response == Dict("id" => "ok", "status" => ["done", "error"], "err" => "request keys must use kebab-case")
    end

    @testset "nested request values are rejected" begin
        response = REPLy.validate_request(Dict("op" => "eval", "id" => "ok", "params" => Dict("code" => "1+1")))
        @test response == Dict("id" => "ok", "status" => ["done", "error"], "err" => "request message must use a flat JSON envelope")
    end

    @testset "valid request returns nothing from validator" begin
        @test isnothing(REPLy.validate_request(Dict("op" => "eval", "id" => "ok", "code" => "1+1", "store-history" => false)))
    end

    @testset "response helpers preserve id echo and kebab-case keys" begin
        value_msg = REPLy.response_message("abc", "value" => "2", "new-session" => "ephemeral")
        done_msg = REPLy.done_response("abc")

        @test value_msg == Dict("id" => "abc", "value" => "2", "new-session" => "ephemeral")
        @test done_msg == Dict("id" => "abc", "status" => ["done"])
        assert_conformance([value_msg, done_msg], "abc")
    end
end
