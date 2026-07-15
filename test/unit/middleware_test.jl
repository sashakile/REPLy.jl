# Custom middleware used to exercise the tuple-based dispatch path in
# build_handler: it delegates via next(msg) and then does work *after* next
# returns (tags terminal frames), proving post-next wrappers still compose.
struct TagTerminalMiddleware <: REPLy.AbstractMiddleware end
function REPLy.handle_message(::TagTerminalMiddleware, msg, next, ctx::REPLy.RequestContext)
    result = next(msg)
    if result isa Vector
        for m in result
            haskey(m, "status") && (m["tagged"] = true)
        end
    end
    return result
end

@testset "middleware" begin
    @testset "build_handler tuple dispatch composes a custom post-next middleware" begin
        stack = REPLy.default_middleware_stack()
        pushfirst!(stack, TagTerminalMiddleware())
        handler = REPLy.build_handler(; middleware=stack)

        # ping goes through the custom wrapper, which tags the terminal frame.
        responses = handler(Dict("op" => "ping", "id" => "mw-tuple-ping"))
        @test any(get(m, "tagged", false) === true for m in responses)
        @test any("pong" in get(m, "status", String[]) for m in responses)

        # eval still works and is tagged too.
        eval_responses = handler(Dict("op" => "eval", "id" => "mw-tuple-eval", "code" => "1 + 1"))
        @test any(get(m, "value", nothing) == "2" for m in eval_responses)
        @test any(get(m, "tagged", false) === true for m in eval_responses)
    end

    @testset "mutable_copy returns a Dict{String,Any} with string keys" begin
        # From a JSON3.Object (how requests actually arrive on the wire).
        obj = JSON3.read("{\"op\":\"eval\",\"id\":\"mc1\",\"n\":5,\"arr\":[1,2]}")
        copy = REPLy.mutable_copy(obj)
        @test copy isa Dict{String, Any}
        @test all(k isa String for k in keys(copy))
        @test copy["op"] == "eval"
        @test copy["id"] == "mc1"
        @test copy["n"] == 5

        # Mutating the copy does not touch the source, and merge composes.
        copy["code"] = "1+1"
        @test !haskey(obj, "code")
        merged = merge(REPLy.mutable_copy(obj), Dict{String, Any}("code" => "2+2"))
        @test merged["code"] == "2+2"
        @test merged["op"] == "eval"

        # Also works on a plain Dict.
        from_dict = REPLy.mutable_copy(Dict("a" => 1, "b" => 2))
        @test from_dict == Dict{String, Any}("a" => 1, "b" => 2)
    end

    @testset "build_handler with an empty stack returns a bare done" begin
        handler = REPLy.build_handler(; middleware=REPLy.AbstractMiddleware[])
        responses = handler(Dict("op" => "anything", "id" => "mw-empty"))
        @test length(responses) == 1
        @test responses[1]["id"] == "mw-empty"
        @test responses[1]["status"] == ["done"]
    end

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
