# Purpose: Map the middleware capability spec's implementation-gap scenarios to
#   executable assertions (openspec/specs/middleware/spec.md, REPLy_jl-tl06):
#   - custom-op-via-middleware
#   - duplicate-provides-symbol-at-startup
#   - missing-required-symbol-causes-startup-failure
#   - default-stack-matches-built-in-order
#   - stack-is-fixed-after-startup
#   - empty-vector-replaced-with-done-response
#   - handler-composed-once-per-connection
# Responsibilities:
#   - Drive a third-party middleware registering a brand-new op through
#     build_handler with no core changes.
#   - Assert startup validation errors name the conflicting middleware TYPES
#     (duplicate provides) and the middleware type plus missing symbol
#     (unsatisfied requires), per REQ-RPL-052.
#   - Assert default_middleware_stack() returns the built-in middleware in the
#     specified order, that the stack is immutable after startup, and that a
#     middleware returning an empty Vector gets a done response plus a warning.
#   - Assert the composed handler is reused for every message on a connection
#     (and across connections) via the real connection loop.
# Rationale: These are the middleware spec's contracts that no existing test
#   covers; startup diagnostics naming types (not just indices) and the
#   empty-vector warning are wire-visible guarantees third-party integrators
#   rely on when their stacks fail validation.
using Test
using Logging
using JSON3

@testset "middleware spec adoption (REPLy_jl-tl06)" begin

    @testset "custom op via middleware" begin
        # Third-party operation registration (REQ-RPL-050): a middleware
        # registers a brand-new op handled without any core changes; eval
        # (core) keeps working on the same stack.
        struct DebuggerMiddleware <: REPLy.AbstractMiddleware end
        function REPLy.handle_message(::DebuggerMiddleware, msg, next, ctx::REPLy.RequestContext)
            get(msg, "op", "") == "set-breakpoint" || return next(msg)
            return Dict{String, Any}("id" => msg["id"], "status" => ["done"],
                                     "result" => "breakpoint set")
        end
        REPLy.descriptor(::DebuggerMiddleware) =
            REPLy.MiddlewareDescriptor(provides=Set(["set-breakpoint"]))

        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(; manager=manager, middleware=REPLy.AbstractMiddleware[
            REPLy.SessionMiddleware(),
            DebuggerMiddleware(),
            REPLy.EvalMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ])

        bp = handler(Dict("op" => "set-breakpoint", "id" => "mw-bp"))
        @test bp isa Vector{Dict{String, Any}}
        @test any(get(m, "result", nothing) == "breakpoint set" for m in bp)
        @test any("done" in get(m, "status", String[]) for m in bp)

        # Core op still routed through the same stack, untouched.
        ev = handler(Dict("op" => "eval", "id" => "mw-bp-eval", "code" => "1 + 1"))
        @test any(get(m, "value", nothing) == "2" for m in ev)

        # Unknown ops still reach the catch-all.
        unk = handler(Dict("op" => "no-such-op", "id" => "mw-bp-unk"))
        @test any("error" in get(m, "status", String[]) for m in unk)
    end

    @testset "duplicate provides symbol at startup names both types" begin
        # Unique provides symbols (REQ-RPL-052): two middleware providing the
        # same symbol must fail startup with an error naming both conflicting
        # middleware types.
        struct ProvidesEvalA <: REPLy.AbstractMiddleware end
        function REPLy.handle_message(::ProvidesEvalA, msg, next, ctx)
            return Dict{String, Any}("id" => msg["id"], "status" => ["done"])
        end
        REPLy.descriptor(::ProvidesEvalA) = REPLy.MiddlewareDescriptor(provides=Set(["eval"]))

        struct ProvidesEvalB <: REPLy.AbstractMiddleware end
        REPLy.descriptor(::ProvidesEvalB) = REPLy.MiddlewareDescriptor(provides=Set(["eval"]))

        errors = REPLy.validate_stack(REPLy.AbstractMiddleware[ProvidesEvalA(), ProvidesEvalB()])
        @test length(errors) == 1
        @test occursin("ProvidesEvalA", errors[1])
        @test occursin("ProvidesEvalB", errors[1])

        # Startup path: build_handler refuses to build the stack.
        err = try
            REPLy.build_handler(middleware=REPLy.AbstractMiddleware[ProvidesEvalA(), ProvidesEvalB()])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("ProvidesEvalA", err.msg)
        @test occursin("ProvidesEvalB", err.msg)
    end

    @testset "missing required symbol at startup names middleware and symbol" begin
        # requires ordering enforced (REQ-RPL-052): the error must name the
        # middleware type and the missing symbol.
        struct RequiresSessionMW <: REPLy.AbstractMiddleware end
        REPLy.descriptor(::RequiresSessionMW) = REPLy.MiddlewareDescriptor(requires=Set(["session"]))

        errors = REPLy.validate_stack(REPLy.AbstractMiddleware[RequiresSessionMW()])
        @test length(errors) == 1
        @test occursin("RequiresSessionMW", errors[1])
        @test occursin("session", errors[1])

        err = try
            REPLy.build_handler(middleware=REPLy.AbstractMiddleware[RequiresSessionMW()])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("RequiresSessionMW", err.msg)
    end

    @testset "default stack matches the built-in order" begin
        # Default middleware stack order (REQ-RPL-055): the exact built-in
        # sequence, from the audit front to the unknown-op catch-all.
        expected_order = [
            REPLy.AuditMiddleware,
            REPLy.ShutdownMiddleware,
            REPLy.SessionMiddleware,
            REPLy.SessionOpsMiddleware,
            REPLy.DescribeMiddleware,
            REPLy.PingMiddleware,
            REPLy.InterruptMiddleware,
            REPLy.StdinMiddleware,
            REPLy.EvalMiddleware,
            REPLy.ReloadFileMiddleware,
            REPLy.LoadFileMiddleware,
            REPLy.CompleteMiddleware,
            REPLy.LookupMiddleware,
            REPLy.LsBindingsMiddleware,
            REPLy.UnknownOpMiddleware,
        ]
        stack = REPLy.default_middleware_stack()
        @test typeof.(stack) == expected_order
    end

    @testset "stack is fixed after startup" begin
        # Middleware stack immutability (ARCH-007): mutating the Vector passed
        # to build_handler after startup must not affect the running handler —
        # not revalidated, not re-materialized.
        struct PostStartupEval <: REPLy.AbstractMiddleware end
        REPLy.descriptor(::PostStartupEval) = REPLy.MiddlewareDescriptor(provides=Set(["eval"]))

        stack = REPLy.AbstractMiddleware[
            REPLy.SessionMiddleware(),
            REPLy.EvalMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ]
        handler = REPLy.build_handler(; middleware=stack)

        # Inject a duplicate-provides middleware: if the stack were
        # re-validated or re-materialized per request, this would throw.
        push!(stack, PostStartupEval())
        @test any(get(m, "value", nothing) == "2" for m in
                  handler(Dict("op" => "eval", "id" => "fixed-1", "code" => "1 + 1")))

        # Empty the stack entirely: the composed handler is untouched.
        empty!(stack)
        @test any(get(m, "value", nothing) == "42" for m in
                  handler(Dict("op" => "eval", "id" => "fixed-2", "code" => "21 * 2")))
    end

    @testset "empty vector replaced with done response" begin
        # Empty response vector guard (ARCH-001): a middleware returning an
        # empty Vector{Dict} yields {"id":..., "status":["done"]} and a warning
        # is logged, preserving one-done-per-request.
        struct EmptyVectorMiddleware <: REPLy.AbstractMiddleware end
        function REPLy.handle_message(::EmptyVectorMiddleware, msg, next, ctx::REPLy.RequestContext)
            return Vector{Dict{String, Any}}()
        end

        logger = Test.TestLogger()
        with_logger(logger) do
            handler = REPLy.build_handler(; middleware=REPLy.AbstractMiddleware[
                REPLy.SessionMiddleware(),
                EmptyVectorMiddleware(),
            ])
            responses = handler(Dict("op" => "anything", "id" => "mw-empty-vec"))
            @test length(responses) == 1
            @test responses[1]["id"] == "mw-empty-vec"
            @test responses[1]["status"] == ["done"]
        end
        @test any(occursin("empty response", lowercase(string(rec.message)))
                  for rec in logger.logs if rec.level == Logging.Warn)
    end

    @testset "handler composed once per connection" begin
        # Handler caching per connection (ARCH-006): the middleware chain is
        # composed once and the resulting handler reused for every message on
        # a connection — observable as every message visiting the SAME
        # middleware instance — and shared across connections of the server.
        mutable struct CountingMiddleware <: REPLy.AbstractMiddleware
            visits::Base.RefValue{Int}
        end
        function REPLy.handle_message(c::CountingMiddleware, msg, next, ctx::REPLy.RequestContext)
            c.visits[] += 1
            return next(msg)
        end

        counting = CountingMiddleware(Ref(0))
        manager = REPLy.SessionManager()
        state = REPLy.ServerState(REPLy.ResourceLimits(), REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        handler = REPLy.build_handler(; manager=manager, state=state,
                                      middleware=REPLy.AbstractMiddleware[
                                          counting,
                                          REPLy.SessionMiddleware(),
                                          REPLy.EvalMiddleware(),
                                          REPLy.UnknownOpMiddleware(),
                                      ])

        # Two connections, three messages total, through the real connection
        # loop (same shape as transport_spec_test's ScriptedTransport).
        mutable struct ScriptedTransport <: REPLy.AbstractTransport
            in::IOBuffer
            out::IOBuffer
            lock::ReentrantLock
            closed::Bool
        end
        function REPLy.send!(t::ScriptedTransport, msg::Dict)
            lock(t.lock) do
                JSON3.write(t.out, msg)
                write(t.out, UInt8('\n'))
            end
            return nothing
        end
        function REPLy.receive(t::ScriptedTransport; max_message_bytes::Int=REPLy.DEFAULT_MAX_MESSAGE_BYTES)
            eof(t.in) && return nothing
            line, terminated = REPLy.read_bounded_line(t.in, max_message_bytes)
            isempty(strip(line)) && return nothing
            terminated || return nothing
            return JSON3.read(line)
        end
        Base.isopen(t::ScriptedTransport) = !t.closed
        Base.close(t::ScriptedTransport) = (t.closed = true; nothing)

        conn1 = ScriptedTransport(
            IOBuffer("{\"op\":\"eval\",\"id\":\"hc-1\",\"code\":\"1+1\"}\n" *
                     "{\"op\":\"eval\",\"id\":\"hc-2\",\"code\":\"2+2\"}\n"),
            IOBuffer(), ReentrantLock(), false)
        conn2 = ScriptedTransport(
            IOBuffer("{\"op\":\"eval\",\"id\":\"hc-3\",\"code\":\"3+3\"}\n"),
            IOBuffer(), ReentrantLock(), false)

        REPLy.handle_client!(conn1, handler; socket=IOBuffer(), state=state)
        REPLy.handle_client!(conn2, handler; socket=IOBuffer(), state=state)

        # Every message on both connections went through the one composed
        # chain (the single CountingMiddleware instance).
        @test counting.visits[] == 3

        # And the responses came back correctly on both connections.
        for conn in (conn1, conn2)
            responses = Dict{String, Any}[]
            for line in eachline(IOBuffer(String(take!(conn.out))))
                isempty(line) || push!(responses, JSON3.read(line, Dict{String, Any}))
            end
            @test any(get(m, "value", nothing) in ("2", "4", "6") for m in responses)
            @test any("done" in get(m, "status", String[]) for m in responses)
        end
    end
end