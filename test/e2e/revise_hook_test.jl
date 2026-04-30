# E2E tests for the Revise.jl pre-eval hook (REQ-RPL-060 / REPLy_jl-4kf).
#
# We cannot install Revise.jl as a test dependency, so we inject a fake
# Revise module into Main before starting the server.  Since the server runs
# in-process, changes to Main are visible to the eval middleware.

@testset "e2e: Revise hook fires before named-session eval" begin
    @testset "hook is called when Revise is loaded in Main" begin
        call_count = Ref(0)
        mock_revise = Module(:Revise)
        Core.eval(mock_revise, :(call_count = $(call_count)))
        Core.eval(mock_revise, :(revise() = (call_count[] += 1; nothing)))
        prior_loaded = get(Base.loaded_modules, REPLy._REVISE_PKG_ID, nothing)
        Base.loaded_modules[REPLy._REVISE_PKG_ID] = mock_revise
        Core.eval(Main, :(const Revise = $mock_revise))

        try
            manager = REPLy.SessionManager()
            REPLy.create_named_session!(manager, "e2e-revise-named")
            server = REPLy.serve(; port=0, manager=manager)
            port   = REPLy.server_port(server)

            try
                sock = connect(port)
                try
                    send_request(sock, Dict(
                        "op"      => "eval",
                        "id"      => "e2e-rh-1",
                        "code"    => "1 + 1",
                        "session" => "e2e-revise-named",
                    ))
                    msgs = collect_until_done(sock)
                    assert_conformance(msgs, "e2e-rh-1")
                    @test any(get(m, "value", nothing) == "2" for m in msgs)
                    @test call_count[] >= 1
                finally
                    close(sock)
                end
            finally
                close(server)
            end
        finally
            if isdefined(Base, :delete_binding)
                Base.delete_binding(Main, :Revise)
            end
            if isnothing(prior_loaded)
                delete!(Base.loaded_modules, REPLy._REVISE_PKG_ID)
            else
                Base.loaded_modules[REPLy._REVISE_PKG_ID] = prior_loaded
            end
        end
    end

    @testset "hook is NOT called for ephemeral evals (no session key)" begin
        call_count = Ref(0)
        mock_revise = Module(:Revise)
        Core.eval(mock_revise, :(call_count = $(call_count)))
        Core.eval(mock_revise, :(revise() = (call_count[] += 1; nothing)))
        prior_loaded = get(Base.loaded_modules, REPLy._REVISE_PKG_ID, nothing)
        Base.loaded_modules[REPLy._REVISE_PKG_ID] = mock_revise
        Core.eval(Main, :(const Revise = $mock_revise))

        try
            with_server(port=0) do handle
                sock = connect(handle.port)
                try
                    send_request(sock, Dict(
                        "op"  => "eval",
                        "id"  => "e2e-rh-eph",
                        "code" => "1 + 1",
                        # no "session" key → ephemeral
                    ))
                    msgs = collect_until_done(sock)
                    assert_conformance(msgs, "e2e-rh-eph")
                    @test any(get(m, "value", nothing) == "2" for m in msgs)
                    @test call_count[] == 0
                finally
                    close(sock)
                end
            end
        finally
            if isdefined(Base, :delete_binding)
                Base.delete_binding(Main, :Revise)
            end
            if isnothing(prior_loaded)
                delete!(Base.loaded_modules, REPLy._REVISE_PKG_ID)
            else
                Base.loaded_modules[REPLy._REVISE_PKG_ID] = prior_loaded
            end
        end
    end

    @testset "hook disabled via revise_hook_enabled=false in ResourceLimits" begin
        call_count = Ref(0)
        mock_revise = Module(:Revise)
        Core.eval(mock_revise, :(call_count = $(call_count)))
        Core.eval(mock_revise, :(revise() = (call_count[] += 1; nothing)))
        prior_loaded = get(Base.loaded_modules, REPLy._REVISE_PKG_ID, nothing)
        Base.loaded_modules[REPLy._REVISE_PKG_ID] = mock_revise
        Core.eval(Main, :(const Revise = $mock_revise))

        try
            limits  = REPLy.ResourceLimits(revise_hook_enabled=false)
            manager = REPLy.SessionManager()
            REPLy.create_named_session!(manager, "e2e-revise-disabled")
            server = REPLy.serve(; port=0, manager=manager, limits=limits)
            port   = REPLy.server_port(server)

            try
                sock = connect(port)
                try
                    send_request(sock, Dict(
                        "op"      => "eval",
                        "id"      => "e2e-rh-off",
                        "code"    => "1 + 1",
                        "session" => "e2e-revise-disabled",
                    ))
                    msgs = collect_until_done(sock)
                    assert_conformance(msgs, "e2e-rh-off")
                    @test any(get(m, "value", nothing) == "2" for m in msgs)
                    @test call_count[] == 0
                finally
                    close(sock)
                end
            finally
                close(server)
            end
        finally
            if isdefined(Base, :delete_binding)
                Base.delete_binding(Main, :Revise)
            end
            if isnothing(prior_loaded)
                delete!(Base.loaded_modules, REPLy._REVISE_PKG_ID)
            else
                Base.loaded_modules[REPLy._REVISE_PKG_ID] = prior_loaded
            end
        end
    end
end
