@testset "ls-bindings middleware" begin
    # Run `code` in `session` via the eval middleware, so the bindings under test
    # are created the same way a client would create them.
    function eval_in!(manager, session, code)
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], session)
        REPLy.handle_message(REPLy.EvalMiddleware(),
            Dict("op" => "eval", "id" => "seed", "code" => code), _ -> nothing, ctx)
    end

    function ls_bindings(manager, session; id="lb")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], session)
        REPLy.handle_message(REPLy.LsBindingsMiddleware(),
            Dict("op" => "ls-bindings", "id" => id), _ -> nothing, ctx)
    end

    @testset "returns user bindings with types, count, and ns" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lb-basic")
        eval_in!(manager, session, "x = 42\ns = \"hi\"\nf(y) = y + 1")

        msgs = ls_bindings(manager, session)
        @test length(msgs) == 2
        result = msgs[1]
        @test msgs[2]["status"] == ["done"]

        @test result["id"] == "lb"
        @test result["ns"] == string(nameof(REPLy.session_module(session)))
        @test result["count"] == length(result["bindings"])

        names_seen = Dict(b["name"] => b["type"] for b in result["bindings"])
        @test names_seen["x"] == "Int64"
        @test names_seen["s"] == "String"
        @test haskey(names_seen, "f")
    end

    @testset "excludes auto-injected names, gensyms, and sub-modules" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lb-exclude")
        eval_in!(manager, session, "z = 1\nmodule Inner end")

        result = ls_bindings(manager, session)[1]
        names_seen = Set(b["name"] for b in result["bindings"])
        @test "z" in names_seen
        @test !("include" in names_seen)
        @test !("eval" in names_seen)
        @test !("Inner" in names_seen)               # sub-module excluded
        @test all(!startswith(n, "#") for n in names_seen)  # gensyms excluded
    end

    @testset "bindings are sorted by name" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lb-sort")
        eval_in!(manager, session, "gamma = 1\nalpha = 2\nbeta = 3")

        result = ls_bindings(manager, session)[1]
        names_only = [b["name"] for b in result["bindings"]]
        @test names_only == sort(names_only)
    end

    @testset "does not list names brought in via `using`" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lb-using")
        eval_in!(manager, session, "using Dates\nmy_var = 7")

        result = ls_bindings(manager, session)[1]
        names_seen = Set(b["name"] for b in result["bindings"])
        @test "my_var" in names_seen
        @test !("now" in names_seen)   # `using` exports are not enumerated
        @test !("Dates" in names_seen)
    end

    @testset "requires a session" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        msgs = REPLy.handle_message(REPLy.LsBindingsMiddleware(),
            Dict("op" => "ls-bindings", "id" => "lb-nosess"), _ -> nothing, ctx)
        @test length(msgs) == 1
        @test "error" in msgs[1]["status"]
        @test occursin("session", msgs[1]["err"])
    end

    @testset "empty session returns empty bindings" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lb-empty")
        result = ls_bindings(manager, session)[1]
        @test result["count"] == 0
        @test isempty(result["bindings"])
    end

    @testset "non-ls-bindings ops are forwarded" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lb-fwd")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], session)
        forwarded = Ref(false)
        REPLy.handle_message(REPLy.LsBindingsMiddleware(),
            Dict("op" => "eval", "id" => "x"), _ -> (forwarded[] = true; []), ctx)
        @test forwarded[]
    end
end
