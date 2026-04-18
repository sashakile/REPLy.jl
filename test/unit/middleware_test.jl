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
        ctx = REPLy.RequestContext(REPLy.SessionManager(), Dict{String, Any}[], REPLy.create_ephemeral_session!(REPLy.SessionManager()))
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
end
