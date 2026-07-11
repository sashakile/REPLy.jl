# Regression test for REPLy_jl-erv: FD exhaustion leak under sustained mixed
# load ("dup: Bad file descriptor"). The original root cause — a per-eval
# dup2 in the IO capture layer — was removed by the TaskCapturingIO refactor,
# and per-session stdin pipes are closed by teardown_stdin_feeder! on destroy.
# This test guards against regressions by driving sustained mixed load
# (stdin-enabled evals, timeouts that exercise the interrupt/teardown path, and
# session create/destroy churn) against one long-lived server and asserting the
# process file-descriptor count stays flat and no "Bad file descriptor" error
# surfaces.
#
# FD counting uses /proc, so the assertions run on Linux only; elsewhere the
# behavioural load still runs but the FD count is not asserted.
@testset "e2e: FD stability under sustained mixed load" begin
    fd_count() = length(readdir("/proc/$(getpid())/fd"))
    can_count_fds = Sys.islinux() && isdir("/proc/$(getpid())/fd")

    server = REPLy.serve(; port=0)
    port = REPLy.server_port(server)
    bad_fd_errors = String[]

    try
        # Warm up: install IO capture and let one session materialize its stdin
        # pipe so the baseline reflects steady-state FD usage.
        warm = connect(port)
        try
            send_request(warm, Dict("op" => "new-session", "id" => "fd-warm-n", "session" => "fd-warm"))
            collect_until_done(warm)
            send_request(warm, Dict("op" => "eval", "id" => "fd-warm-e",
                "session" => "fd-warm", "code" => "println(\"warm\"); 1+1", "allow-stdin" => true))
            collect_until_done(warm)
        finally
            close(warm)
        end
        GC.gc(); sleep(0.2)
        baseline = can_count_fds ? fd_count() : 0

        for round in 1:5
            for i in 1:8
                name = "fd-sess-$i"
                sock = connect(port)
                try
                    send_request(sock, Dict("op" => "new-session", "id" => "fd-n-$round-$i",
                        "session" => name, "if-exists" => "reuse"))
                    collect_until_done(sock)

                    # stdin-enabled eval (materializes the per-session stdin pipe).
                    send_request(sock, Dict("op" => "eval", "id" => "fd-e-$round-$i",
                        "session" => name, "code" => "println(\"hi\"); 2+2", "allow-stdin" => true))
                    for m in collect_until_done(sock)
                        if occursin("Bad file descriptor", get(m, "err", ""))
                            push!(bad_fd_errors, m["err"])
                        end
                    end

                    # Timeout eval — drives the interrupt + teardown path.
                    send_request(sock, Dict("op" => "eval", "id" => "fd-t-$round-$i",
                        "session" => name, "code" => "sleep(30)", "timeout-ms" => 50,
                        "allow-stdin" => true))
                    for m in collect_until_done(sock)
                        if occursin("Bad file descriptor", get(m, "err", ""))
                            push!(bad_fd_errors, m["err"])
                        end
                    end
                finally
                    close(sock)
                end
            end

            # Destroy the sessions created this round; teardown must close pipes.
            d = connect(port)
            try
                for i in 1:8
                    send_request(d, Dict("op" => "close-session", "id" => "fd-c-$round-$i",
                        "session" => "fd-sess-$i"))
                    collect_until_done(d)
                end
            finally
                close(d)
            end
            GC.gc(); sleep(0.1)
        end

        GC.gc(); sleep(0.3)

        @test isempty(bad_fd_errors)

        if can_count_fds
            final = fd_count()
            # Allow a small slack for transient connection FDs; a leak would grow
            # with each of the 40 evals, far exceeding this bound.
            @test final <= baseline + 5
        end
    finally
        close(server)
    end
end
