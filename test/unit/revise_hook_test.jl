# Unit tests for the Revise.jl pre-eval hook (REQ-RPL-060 / REPLy_jl-4kf).
#
# Revise.jl is NOT a test dependency, so we inject a fake Revise module into
# Main before each test and clean up afterwards.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

"""
    with_mock_revise(f; fail=false)

Inject a fake `Revise` module into `Main` for the duration of `f`.

If `fail=true`, the `revise()` function throws an error, letting us verify
that the hook swallows it and emits a @warn instead of aborting the eval.

Cleans up by removing the binding from `Main` regardless of whether `f`
throws, so individual tests stay isolated.
"""
function with_mock_revise(f; fail::Bool=false)
    call_count = Ref(0)
    mod = Module(:Revise)
    if fail
        Core.eval(mod, :(revise() = error("Revise exploded")))
    else
        Core.eval(mod, :(call_count = $(call_count)))
        Core.eval(mod, :(revise() = (call_count[] += 1; nothing)))
    end
    # Register the mock in Base.loaded_modules under the authentic Revise PkgId
    # so the security check in _revise_if_present passes.  Capture any prior
    # entry so we can restore it on teardown.
    prior_loaded = get(Base.loaded_modules, REPLy._REVISE_PKG_ID, nothing)
    Base.loaded_modules[REPLy._REVISE_PKG_ID] = mod
    Core.eval(Main, :(const Revise = $mod))
    try
        f(call_count)
    finally
        # Remove the Revise binding from Main so it doesn't bleed into later tests.
        # Base.delete_binding is available in Julia 1.11+; fall back to a no-op
        # (the module is still safe to garbage-collect once the test exits).
        if isdefined(Base, :delete_binding)
            Base.delete_binding(Main, :Revise)
        end
        # Restore Base.loaded_modules to its prior state.
        if isnothing(prior_loaded)
            delete!(Base.loaded_modules, REPLy._REVISE_PKG_ID)
        else
            Base.loaded_modules[REPLy._REVISE_PKG_ID] = prior_loaded
        end
    end
end

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@testset "Revise hook: named session" begin
    @testset "hook calls Revise.revise() when Revise is loaded" begin
        with_mock_revise() do call_count
            manager = REPLy.SessionManager()
            session = REPLy.create_named_session!(manager, "revise-named-1")
            mw      = REPLy.EvalMiddleware()
            ctx     = REPLy.RequestContext(manager, Dict{String,Any}[], session)

            msgs = REPLy.handle_message(
                mw,
                Dict("op" => "eval", "id" => "rh-named-1", "code" => "1 + 1"),
                _ -> nothing,
                ctx,
            )

            @test call_count[] == 1
            @test any(get(m, "value", nothing) == "2" for m in msgs)
        end
    end

    @testset "hook is called before each eval in successive requests" begin
        with_mock_revise() do call_count
            manager = REPLy.SessionManager()
            session = REPLy.create_named_session!(manager, "revise-named-2")
            mw      = REPLy.EvalMiddleware()
            ctx     = REPLy.RequestContext(manager, Dict{String,Any}[], session)

            REPLy.handle_message(mw,
                Dict("op" => "eval", "id" => "rh-named-2a", "code" => "1"),
                _ -> nothing, ctx)
            REPLy.handle_message(mw,
                Dict("op" => "eval", "id" => "rh-named-2b", "code" => "2"),
                _ -> nothing, ctx)

            @test call_count[] == 2
        end
    end

    @testset "hook error is suppressed — eval still succeeds" begin
        with_mock_revise(; fail=true) do _call_count
            manager = REPLy.SessionManager()
            session = REPLy.create_named_session!(manager, "revise-named-err")
            mw      = REPLy.EvalMiddleware()
            ctx     = REPLy.RequestContext(manager, Dict{String,Any}[], session)

            msgs = REPLy.handle_message(
                mw,
                Dict("op" => "eval", "id" => "rh-named-err", "code" => "42"),
                _ -> nothing,
                ctx,
            )

            # Eval should still complete successfully despite the hook error.
            done_msg = only(filter(m -> haskey(m, "status") && "done" in m["status"], msgs))
            @test "done" in done_msg["status"]
            @test !("error" in done_msg["status"])
            @test any(get(m, "value", nothing) == "42" for m in msgs)
        end
    end

    @testset "hook is disabled when revise_hook_enabled=false in server limits" begin
        with_mock_revise() do call_count
            limits  = REPLy.ResourceLimits(revise_hook_enabled=false)
            manager = REPLy.SessionManager()
            state   = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
            session = REPLy.create_named_session!(manager, "revise-disabled")
            mw      = REPLy.EvalMiddleware()
            ctx     = REPLy.RequestContext(manager, Dict{String,Any}[], session, state)

            REPLy.handle_message(
                mw,
                Dict("op" => "eval", "id" => "rh-disabled", "code" => "1"),
                _ -> nothing,
                ctx,
            )

            @test call_count[] == 0
        end
    end
end

@testset "Revise hook: ephemeral session" begin
    @testset "hook is NOT called for ephemeral sessions" begin
        with_mock_revise() do call_count
            manager = REPLy.SessionManager()
            # No session in ctx — EvalMiddleware will create an ephemeral one.
            ctx = REPLy.RequestContext(manager, Dict{String,Any}[], nothing)

            mw = REPLy.EvalMiddleware()
            REPLy.handle_message(
                mw,
                Dict("op" => "eval", "id" => "rh-eph", "code" => "1"),
                _ -> nothing,
                ctx,
            )

            @test call_count[] == 0
        end
    end
end

@testset "Revise hook: shadow-module injection" begin
    @testset "hook ignores a fake Revise module not in Base.loaded_modules" begin
        # Simulate an attacker eval-ing 'module Revise; revise()=<payload>; end'.
        # The shadow module is bound in Main but NOT registered in Base.loaded_modules.
        call_count = Ref(0)
        shadow = Module(:Revise)
        Core.eval(shadow, :(call_count = $(call_count)))
        Core.eval(shadow, :(revise() = (call_count[] += 1; nothing)))
        Core.eval(Main, :(const Revise = $shadow))
        # Ensure the shadow is NOT in Base.loaded_modules.
        delete!(Base.loaded_modules, REPLy._REVISE_PKG_ID)
        try
            manager = REPLy.SessionManager()
            session = REPLy.create_named_session!(manager, "revise-shadow")
            mw      = REPLy.EvalMiddleware()
            ctx     = REPLy.RequestContext(manager, Dict{String,Any}[], session)

            msgs = REPLy.handle_message(
                mw,
                Dict("op" => "eval", "id" => "rh-shadow", "code" => "1 + 1"),
                _ -> nothing,
                ctx,
            )

            @test call_count[] == 0  # Shadow module MUST NOT be called
            @test any(get(m, "value", nothing) == "2" for m in msgs)
        finally
            if isdefined(Base, :delete_binding)
                Base.delete_binding(Main, :Revise)
            end
        end
    end
end

@testset "Revise hook: Revise not loaded" begin
    @testset "no-op when Revise is not defined in Main" begin
        # Ensure Revise is NOT in Main for this test.
        had_revise = isdefined(Main, :Revise)
        had_revise && @warn "Revise already defined in Main — skipping no-Revise test"
        had_revise && return

        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "revise-absent")
        mw      = REPLy.EvalMiddleware()
        ctx     = REPLy.RequestContext(manager, Dict{String,Any}[], session)

        msgs = REPLy.handle_message(
            mw,
            Dict("op" => "eval", "id" => "rh-absent", "code" => "1 + 1"),
            _ -> nothing,
            ctx,
        )

        @test any(get(m, "value", nothing) == "2" for m in msgs)
    end
end
