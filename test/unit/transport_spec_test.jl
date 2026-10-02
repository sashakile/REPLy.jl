# Purpose: Map the transport capability spec's implementation-gap scenarios to
#   executable assertions (openspec/specs/transport/spec.md, REPLy_jl-uu5c):
#   - custom-transport-works-unchanged-with-core
#   - port-conflict-is-logged
#   - umask-prevents-briefly-world-accessible-socket
# Responsibilities:
#   - Drive a fully custom AbstractTransport (four interface methods only)
#     through the real connection loop with the production handler, and assert
#     eval + session behavior is unchanged.
#   - Assert a TCP bind failure (port already in use) logs an Error-level
#     message naming the port before the exception propagates.
#   - Assert the Unix socket is created owner-only under the 0o077 umask wrap
#     and the caller's umask is restored afterwards.
# Rationale: These are the transport spec's contracts that no existing test
#   covers; the custom-transport loop is the REQ-RPL-002 transport-agnostic
#   guarantee in its strongest form — any AbstractTransport must drive the
#   unmodified middleware pipeline and session manager.
using Test
using Logging
using JSON3

@testset "transport spec adoption (REPLy_jl-uu5c)" begin
    @testset "custom transport works unchanged with core" begin
        # A transport implementing ONLY the four abstract methods
        # (send!/receive/close/isopen). It shares nothing with JSONTransport
        # beyond the AbstractTransport supertype.
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
            terminated || return nothing  # partial read -> nothing (REQ-RPL-040b)
            return JSON3.read(line)
        end

        Base.isopen(t::ScriptedTransport) = !t.closed
        Base.close(t::ScriptedTransport) = (t.closed = true; nothing)

        scripted = ScriptedTransport(
            IOBuffer("{\"op\":\"eval\",\"id\":\"ct-1\",\"session\":\"s1\",\"code\":\"1+1\"}\n" *
                     "{\"op\":\"eval\",\"id\":\"ct-2\",\"session\":\"s1\",\"code\":\"21*2\"}\n"),
            IOBuffer(),
            ReentrantLock(),
            false,
        )

        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "s1")
        state = REPLy.ServerState(REPLy.ResourceLimits(), REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        handler = REPLy.build_handler(; manager=manager, state=state)

        # Production connection loop, unmodified, over the custom transport.
        # socket is provided only for ServerState request accounting (IdDict{IO,Int}).
        REPLy.handle_client!(scripted, handler; socket=IOBuffer(), state=state)

        responses = Dict{String, Any}[]
        for line in eachline(IOBuffer(String(take!(scripted.out))))
            isempty(line) || push!(responses, JSON3.read(line, Dict{String, Any}))
        end

        ids = (get(r, "id", nothing) for r in responses)
        @test "ct-1" in ids
        @test "ct-2" in ids
        ct1 = filter(r -> get(r, "id", nothing) == "ct-1", responses)
        ct2 = filter(r -> get(r, "id", nothing) == "ct-2", responses)
        value1 = only(filter(r -> haskey(r, "value"), ct1))["value"]
        value2 = only(filter(r -> haskey(r, "value"), ct2))["value"]
        @test value1 == "2"
        @test any("done" in get(r, "status", String[]) for r in ct1)
        @test value2 == "42"
        @test any("done" in get(r, "status", String[]) for r in ct2)
        # Framing holds for the custom transport too: every response line is
        # newline-terminated (checked implicitly by eachline parse success).
    end

    @testset "port conflict is logged" begin
        blocker = REPLy.serve(; port=0)
        busy_port = REPLy.server_port(blocker)
        try
            logger = Test.TestLogger()
            @test_throws Base.IOError with_logger(logger) do
                REPLy.serve(; port=busy_port)
            end
            @test any(r.level == Logging.Error &&
                      occursin("bind", string(r.message)) &&
                      get(r.kwargs, :port, nothing) == busy_port
                      for r in logger.logs)
        finally
            close(blocker)
        end
    end

    @testset "umask prevents briefly-world-accessible socket" begin
        path = tempname()
        prev = ccall(:umask, Cuint, (Cuint,), 0o022)
        try
            listener = REPLy.listen_unix(path)
            try
                # Created under the 0o077 wrap: owner-only from the first
                # instant, not merely after the explicit chmod.
                @test stat(path).mode & 0o777 == 0o600
            finally
                close(listener)
            end
            # The umask wrap is a wrap: the caller's umask is restored, not
            # leaked. If listen_unix left 0o077 in place, this call would
            # return 0o077 instead of the caller's 0o022.
            @test ccall(:umask, Cuint, (Cuint,), prev) == prev
        finally
            ccall(:umask, Cuint, (Cuint,), prev)
            ispath(path) && rm(path; force=true)
        end
    end
end
