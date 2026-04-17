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
            @test REPLy.receive(transport) == Dict("op" => "eval", "id" => "1", "code" => "1+1")
        end

        @testset "receive skips blank and whitespace lines" begin
            transport = REPLy.JSONTransport(IOBuffer("\n   \n{\"op\":\"eval\",\"id\":\"1\",\"code\":\"1+1\"}\n"), ReentrantLock())
            @test REPLy.receive(transport) == Dict("op" => "eval", "id" => "1", "code" => "1+1")
        end

        @testset "receive returns nothing on malformed JSON" begin
            transport = REPLy.JSONTransport(IOBuffer("{\"op\":\"eval\",\"id\":}\n"), ReentrantLock())
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
            @test REPLy.receive(transport) == Dict("op" => "eval", "id" => "1", "code" => "1+1")
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
