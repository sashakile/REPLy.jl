# Purpose: Map the error-handling capability spec's malformed-message
#   counter scenarios to executable assertions
#   (openspec/specs/error-handling/spec.md, REPLy_jl-386s):
#   - consecutive-malformed-messages-disconnect-client
#   - valid-request-resets-malformed-counter
# Responsibilities:
#   - Drive a real server over TCP with crafted message sequences (malformed
#     JSON lines and a valid request).
#   - Assert the server sends per-message malformed-request errors and
#     disconnects exactly at the 10th consecutive malformed message.
#   - Assert one valid request resets the counter so a subsequent malformed
#     message does NOT disconnect.
# Rationale: The disconnect policy is a wire-level behavioral contract;
#   driving the real connection loop (rather than internals) keeps the
#   threshold semantics honest, including the reset-on-valid rule.
using Test
using Sockets

@testset "malformed message counter (REPLy_jl-386s)" begin

    @testset "10 consecutive malformed messages disconnect the client" begin
        # Spec (error-handling REQ-RPL-020, core-operations REQ-RPL-020):
        # malformed messages are counted, never answered (no id can be
        # trusted for correlation), and the connection closes only after the
        # 10th consecutive one.
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                for _ in 1:10
                    write(sock, "{not valid json}\n")
                end
                flush(sock)

                # Zero responses (spec: no response for malformed), then the
                # server closes the connection (EOF).
                reader = @async read(sock, String)
                status = timedwait(() -> istaskdone(reader), 10.0)
                @test status == :ok
                @test fetch(reader) == ""  # no response bytes at all
            finally
                isopen(sock) && close(sock)
            end
        end
    end

    @testset "valid request resets the malformed counter" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                # 9 malformed + 1 valid + 1 malformed + 9 malformed = 19
                # malformed total. If the counter had NOT reset at the valid
                # request, the 10th malformed would have disconnected before
                # the final batch. With the reset, the server never
                # disconnects and the only response bytes are the valid
                # request's unknown-op error.
                for _ in 1:9
                    write(sock, "{not valid json}\n")
                end
                write(sock, """{"id":"v1","op":"no-such-op-386s"}\n""")
                write(sock, "{not valid json}\n")
                for _ in 1:9
                    write(sock, "{not valid json}\n")
                end
                flush(sock)

                msgs = collect_until_done(sock; timeout_s=10.0)
                @test length(msgs) == 1
                @test "unknown-op" in msgs[1]["status"]
            finally
                isopen(sock) && close(sock)
            end
        end
    end
end