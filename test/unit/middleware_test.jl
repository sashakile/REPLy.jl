@testset "middleware" begin
    @testset "eval middleware passes through unhandled ops" begin
        ctx = REPLy.RequestContext(REPLy.SessionManager(), Dict{String, Any}[], nothing)
        called = Ref(false)
        request = Dict("op" => "describe", "id" => "mw-pass")

        response = REPLy.handle_message(
            REPLy.EvalMiddleware(),
            request,
            msg -> begin
                called[] = true
                Dict("id" => msg["id"], "status" => ["done"])
            end,
            ctx,
        )

        @test called[]
        @test response == Dict("id" => "mw-pass", "status" => ["done"])
    end

    @testset "eval middleware intercepts eval without delegating" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], REPLy.create_ephemeral_session!(manager))
        called = Ref(false)
        request = Dict("op" => "eval", "id" => "mw-handle", "code" => "1 + 1")

        responses = REPLy.handle_message(
            REPLy.EvalMiddleware(),
            request,
            msg -> begin
                called[] = true
                Dict("id" => msg["id"], "status" => ["done"])
            end,
            ctx,
        )

        @test !called[]
        @test responses isa Vector{Dict{String, Any}}
        @test any(get(msg, "value", nothing) == "2" for msg in responses)
        @test any(get(msg, "status", String[]) == ["done"] for msg in responses)
    end

    @testset "custom eval-only stack does not leak fallback sessions" begin
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager, middleware=REPLy.AbstractMiddleware[REPLy.EvalMiddleware()])

        @test REPLy.session_count(manager) == 0
        responses = handler(Dict("op" => "eval", "id" => "mw-cleanup", "code" => "1 + 1"))

        @test any(get(msg, "value", nothing) == "2" for msg in responses)
        @test REPLy.session_count(manager) == 0
    end
end
