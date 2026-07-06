@testset "reload-file middleware" begin
    # Stack: ReloadFileMiddleware must come before LoadFileMiddleware.
    function reload_stack(; allow = _ -> true)
        REPLy.AbstractMiddleware[
            REPLy.ReloadFileMiddleware(; load_file_allowlist = allow),
            REPLy.LoadFileMiddleware(; load_file_allowlist = allow),
            REPLy.UnknownOpMiddleware(),
        ]
    end

    @testset "reload re-includes a module file and using .Mod: f works" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "reload-sess")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], session)
        stack = reload_stack()

        file = tempname() * ".jl"
        try
            write(file, "module Foo\nf() = 1\nexport f\nend")
            # First load.
            msgs = REPLy.dispatch_middleware(stack, 1,
                Dict("op" => "reload-file", "id" => "rl1", "file" => file), ctx)
            assert_conformance(msgs, "rl1")

            # Edit the file: f now returns 2.
            write(file, "module Foo\nf() = 2\nexport f\nend")
            msgs = REPLy.dispatch_middleware(stack, 1,
                Dict("op" => "reload-file", "id" => "rl2", "file" => file), ctx)
            assert_conformance(msgs, "rl2")

            # The fresh module binding is unambiguous: using .Foo: f resolves and
            # reflects the reloaded definition.
            mod = REPLy.session_module(session)
            Core.eval(mod, :(using .Foo: f))
            @test Core.eval(mod, :(f())) == 2
        finally
            rm(file; force=true)
        end
    end

    @testset "reload works for a file without a module (plain forward to load-file)" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "reload-plain")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], session)
        stack = reload_stack()

        file = tempname() * ".jl"
        try
            write(file, "y = 10\ny * 4")
            msgs = REPLy.dispatch_middleware(stack, 1,
                Dict("op" => "reload-file", "id" => "rl-plain", "file" => file), ctx)
            assert_conformance(msgs, "rl-plain")
            value_msg = only(filter(m -> haskey(m, "value"), msgs))
            @test value_msg["value"] == "40"
        finally
            rm(file; force=true)
        end
    end

    @testset "reload without a named session returns an error" begin
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
        stack = reload_stack()

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "reload-file", "id" => "rl-nosess", "file" => "/tmp/x.jl"), ctx)
        @test "error" in msgs[end]["status"]
        @test occursin("named session", msgs[end]["err"])
    end

    @testset "reload without file field returns an error" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "reload-nofile")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], session)
        stack = reload_stack()

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "reload-file", "id" => "rl-nofile"), ctx)
        @test "error" in msgs[end]["status"]
    end

    @testset "reload denied by allowlist before any file read" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "reload-deny")
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], session)
        stack = reload_stack(allow = _ -> false)

        msgs = REPLy.dispatch_middleware(stack, 1,
            Dict("op" => "reload-file", "id" => "rl-deny", "file" => "/etc/passwd"), ctx)
        @test "error" in msgs[end]["status"]
        @test "path-not-allowed" in msgs[end]["status"]
    end

    @testset "reload-file is provided by the default middleware stack (describe)" begin
        handler = REPLy.build_handler()
        responses = handler(Dict("op" => "describe", "id" => "rl-desc"))
        ops = only(responses)["ops"]
        @test haskey(ops, "reload-file")
    end
end
