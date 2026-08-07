@testset "concurrent eval serialization" begin
    @testset "concurrent ephemeral evals complete in parallel, not serial" begin
        handler = REPLy.build_handler()

        # Warmup: force JIT so timing is accurate
        handler(Dict("op" => "eval", "id" => "w0", "code" => "1+1"))

        n = 3
        sleep_s = 0.15

        start = time()
        tasks = map(1:n) do i
            @async handler(Dict("op" => "eval", "id" => "par-$i",
                                "code" => "sleep($sleep_s); $i"))
        end
        results = fetch.(tasks)
        elapsed = time() - start

        # Serial: n * sleep_s ≈ 0.45s. Concurrent: ~sleep_s ≈ 0.15s.
        # Accept anything under 3 * sleep_s as evidence of concurrency
        # (generous margin for system load / scheduler overhead).
        @test elapsed < 3 * sleep_s

        for i in 1:n
            @test any(get(msg, "value", nothing) == string(i) for msg in results[i])
        end
    end

    @testset "per-task IO capture: each concurrent eval sees only its own output" begin
        handler = REPLy.build_handler()
        handler(Dict("op" => "eval", "id" => "w1", "code" => "1"))  # warmup

        tasks = map(1:3) do i
            @async handler(Dict("op" => "eval", "id" => "cap-$i",
                                "code" => "sleep(0.05); println(\"marker-$i\"); $i"))
        end
        results = fetch.(tasks)

        for i in 1:3
            out_msgs = filter(msg -> haskey(msg, "out"), results[i])
            captured = join(getindex.(out_msgs, "out"))
            @test occursin("marker-$i", captured)
            for j in 1:3
                j == i && continue
                @test !occursin("marker-$j", captured)
            end
        end
    end
end

@testset "zombie eval lifecycle barriers" begin
    terminal(msgs) = filter(m -> "done" in get(m, "status", String[]), msgs)

    @testset "close cancels named eval and load-file while they wait at the global gate" begin
        for queued_op in (:eval, :load_file)
            manager = REPLy.SessionManager()
            state = REPLy.ServerState(REPLy.ResourceLimits(max_concurrent_evals=1), REPLy.DEFAULT_MAX_MESSAGE_BYTES)
            session = REPLy.create_named_session!(manager, "gate-close")
            entered = Channel{Nothing}(1); release = Channel{Nothing}(1); executed = Channel{Nothing}(1)
            Core.eval(REPLy.session_module(session), :(entered=$entered; release=$release; executed=$executed))
            stack = REPLy.AbstractMiddleware[
                mw isa REPLy.LoadFileMiddleware ? REPLy.LoadFileMiddleware(; load_file_allowlist=_ -> true) : mw
                for mw in REPLy.default_middleware_stack()
            ]
            handler = REPLy.build_handler(; manager, state, middleware=stack)
            first = @async handler(Dict("op" => "eval", "id" => "gate-running", "session" => "gate-close",
                "code" => "put!(entered, nothing); hold() = try; take!(release); catch; hold(); end; hold()"))
            take!(entered)
            queued = if queued_op === :eval
                @async handler(Dict("op" => "eval", "id" => "gate-queued", "session" => "gate-close",
                    "code" => "put!(executed, nothing)"))
            else
                path, io = mktemp(); write(io, "put!(executed, nothing)"); close(io)
                @async try
                    handler(Dict("op" => "load-file", "id" => "gate-queued", "session" => "gate-close", "file" => path))
                finally
                    rm(path; force=true)
                end
            end
            @test timedwait(() -> length(state.gate.queue) == 1 && length(session.eval_queue) == 1, 1.0) === :ok
            handler(Dict("op" => "close", "id" => "gate-close-request", "session" => "gate-close"))
            @test timedwait(() -> istaskdone(queued), 1.0) === :ok
            queued_terminal = last(fetch(queued))
            @test queued_terminal["status"] == ["done", "error", "session-not-found"]
            @test queued_terminal["err"] == "Session not found: gate-close"
            @test !isready(executed)
            @test isempty(state.gate.queue)
            @test isempty(session.eval_queue)
            @test REPLy.active_count(state.gate) == 1
            put!(release, nothing)
            @test timedwait(() -> istaskdone(first) && REPLy.active_count(state.gate) == 0, 2.0) === :ok
        end
    end

    @testset "close cleans a session whose only lifecycle is waiting at the global gate" begin
        manager = REPLy.SessionManager()
        state = REPLy.ServerState(REPLy.ResourceLimits(max_concurrent_evals=1), REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        REPLy.create_named_session!(manager, "gate-only")
        @test REPLy.acquire!(state.gate) # unrelated work owns the sole permit
        handler = REPLy.build_handler(; manager, state)
        waiting = @async handler(Dict("op" => "eval", "id" => "gate-only-waiter",
            "session" => "gate-only", "code" => "error(\"must not execute\")"))
        @test timedwait(() -> length(state.gate.queue) == 1, 1.0) === :ok

        handler(Dict("op" => "close", "id" => "gate-only-close", "session" => "gate-only"))

        @test timedwait(() -> istaskdone(waiting), 1.0) === :ok
        waiting_terminal = last(fetch(waiting))
        @test waiting_terminal["status"] == ["done", "error", "session-not-found"]
        @test waiting_terminal["err"] == "Session not found: gate-only"
        @test isempty(state.gate.queue)
        @test REPLy.total_session_count(manager) == 0
        @test REPLy.active_count(state.gate) == 1
        REPLy.release!(state.gate)
        @test REPLy.active_count(state.gate) == 0
    end

    @testset "session-queued eval and load-file receive quarantine status without executing" begin
        for queued_op in (:eval, :load_file)
            manager = REPLy.SessionManager()
            limits = REPLy.ResourceLimits(max_concurrent_evals=2, max_eval_time_ms=500)
            state = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
            session = REPLy.create_named_session!(manager, "queued-quarantine")
            entered = Channel{Nothing}(1); release = Channel{Nothing}(1); executed = Channel{Nothing}(1)
            Core.eval(REPLy.session_module(session), :(entered=$entered; release=$release; executed=$executed))
            stack = REPLy.AbstractMiddleware[
                mw isa REPLy.LoadFileMiddleware ? REPLy.LoadFileMiddleware(; load_file_allowlist=_ -> true) : mw
                for mw in REPLy.default_middleware_stack()
            ]
            handler = REPLy.build_handler(; manager, state, middleware=stack)
            running = @async handler(Dict("op" => "eval", "id" => "quarantine-running",
                "session" => "queued-quarantine", "timeout-ms" => 500,
                "code" => "put!(entered, nothing); hold() = try; take!(release); catch; hold(); end; hold()"))
            take!(entered)
            mktemp() do path, io
                write(io, "put!(executed, nothing)"); close(io)
                queued = queued_op === :eval ?
                    @async(handler(Dict("op" => "eval", "id" => "quarantine-queued",
                        "session" => "queued-quarantine", "code" => "put!(executed, nothing)"))) :
                    @async(handler(Dict("op" => "load-file", "id" => "quarantine-queued",
                        "session" => "queued-quarantine", "file" => path)))
                @test timedwait(() -> length(session.eval_queue) == 1, 1.0) === :ok
                @test timedwait(() -> istaskdone(running) && istaskdone(queued), 2.0) === :ok
                @test "timeout" in last(fetch(running))["status"]
                queued_terminal = last(fetch(queued))
                @test queued_terminal["status"] == ["done", "error", "session-quarantined"]
                @test queued_terminal["err"] == "Session quarantined after eval timeout"
                @test !isready(executed)
            end
            put!(release, nothing)
            @test timedwait(() -> REPLy.active_count(state.gate) == 0, 2.0) === :ok
            handler(Dict("op" => "close", "id" => "quarantine-close", "session" => "queued-quarantine"))
            @test REPLy.total_session_count(manager) == 0
        end
    end

    @testset "production close cancels queued named evals and detached work cleans exactly once" begin
        manager = REPLy.SessionManager()
        state = REPLy.ServerState(REPLy.ResourceLimits(max_concurrent_evals=3), REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        session = REPLy.create_named_session!(manager, "close-queue")
        entered = Channel{Nothing}(1); release = Channel{Nothing}(1); executed = Channel{String}(2)
        Core.eval(REPLy.session_module(session), :(entered=$entered; release=$release; executed=$executed))
        handler = REPLy.build_handler(; manager, state)
        running = @async handler(Dict("op" => "eval", "id" => "running", "session" => "close-queue",
            "code" => "put!(entered, nothing); hold() = try; take!(release); catch; hold(); end; hold(); :released"))
        take!(entered)
        queued = [@async handler(Dict("op" => "eval", "id" => "queued-$i", "session" => "close-queue",
            "code" => "put!(executed, \"queued-$i\")")) for i in 1:2]
        @test timedwait(() -> length(session.eval_queue) == 2, 1.0) === :ok

        closed = handler(Dict("op" => "close", "id" => "close", "session" => "close-queue"))
        @test "done" in last(closed)["status"]
        @test all(t -> timedwait(() -> istaskdone(t), 1.0) === :ok, queued)
        @test all(t -> last(fetch(t))["status"] == ["done", "error", "session-not-found"], queued)
        @test all(t -> last(fetch(t))["err"] == "Session not found: close-queue", queued)
        @test !isready(executed)
        @test isnothing(REPLy.lookup_named_session(manager, "close-queue"))
        @test REPLy.total_session_count(manager) == 1

        put!(release, nothing)
        @test timedwait(() -> istaskdone(running), 1.0) === :ok
        @test timedwait(() -> REPLy.total_session_count(manager) == 0 &&
            isempty(REPLy.active_eval_tasks(state)) && REPLy.active_count(state.gate) == 0, 1.0) === :ok
        @test !isready(executed)
        @test isempty(session.eval_queue)
    end

    @testset "real eval and load-file share named-session FIFO and ephemeral accounting" begin
        manager = REPLy.SessionManager()
        state = REPLy.ServerState(REPLy.ResourceLimits(max_concurrent_evals=3), REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        session = REPLy.create_named_session!(manager, "mixed-fifo")
        entered = Channel{Nothing}(1); release = Channel{Nothing}(1); order = Channel{Symbol}(3)
        Core.eval(REPLy.session_module(session), :(entered=$entered; release=$release; order=$order))
        stack = REPLy.AbstractMiddleware[
            mw isa REPLy.LoadFileMiddleware ? REPLy.LoadFileMiddleware(; load_file_allowlist=_ -> true) : mw
            for mw in REPLy.default_middleware_stack()
        ]
        handler = REPLy.build_handler(; manager, state, middleware=stack)
        mktemp() do path, io
            write(io, "put!(order, :load); :loaded")
            close(io)
            first = @async handler(Dict("op" => "eval", "id" => "mixed-1", "session" => "mixed-fifo",
                "code" => "put!(entered, nothing); take!(release); put!(order, :eval1); :first"))
            take!(entered)
            loaded = @async handler(Dict("op" => "load-file", "id" => "mixed-load",
                "session" => "mixed-fifo", "file" => path))
            last_eval = @async handler(Dict("op" => "eval", "id" => "mixed-2",
                "session" => "mixed-fifo", "code" => "put!(order, :eval2); :last"))
            @test timedwait(() -> length(session.eval_queue) == 2, 1.0) === :ok
            put!(release, nothing)
            @test all(t -> timedwait(() -> istaskdone(t), 1.0) === :ok, (first, loaded, last_eval))
            @test [take!(order) for _ in 1:3] == [:eval1, :load, :eval2]
            @test isempty(session.eval_queue)
            @test isempty(REPLy.active_eval_tasks(state))
            @test REPLy.active_count(state.gate) == 0

            open(path, "w") do ephemeral_io
                write(ephemeral_io, ":loaded")
            end
            ephemeral = handler(Dict("op" => "load-file", "id" => "ephemeral-load", "file" => path))
            @test any(get(m, "value", nothing) == ":loaded" for m in ephemeral)
            @test REPLy.session_count(manager) == 0
            @test REPLy.total_session_count(manager) == 1
        end
    end

    @testset "interrupt completion on either side of deadline is exactly once" begin
        for (release_after_deadline, expected) in ((false, "interrupted"), (true, "timeout"))
            manager = REPLy.SessionManager()
            session = REPLy.create_named_session!(manager, "deadline")
            release = Channel{Nothing}(1)
            entered = Channel{Nothing}(1)
            Core.eval(REPLy.session_module(session), :(release = $release; entered = $entered))
            handler = REPLy.build_handler(; manager)
            result = @async handler(Dict("op" => "eval", "id" => "deadline-eval",
                "session" => "deadline", "timeout-ms" => 500,
                "code" => "put!(entered, nothing); try; take!(release); catch; $(release_after_deadline ? "while !isready(release); try; sleep(0.01); catch; end; end; take!(release)" : "rethrow()"); end"))
            take!(entered)
            interrupt = handler(Dict("op" => "interrupt", "id" => "deadline-int", "session" => "deadline"))
            @test length(terminal(interrupt)) == 1
            release_after_deadline || put!(release, nothing)
            if release_after_deadline
                @test timedwait(() -> istaskdone(result), 1.0) === :ok
                put!(release, nothing)
            end
            msgs = fetch(result)
            @test length(terminal(msgs)) == 1
            @test expected in only(terminal(msgs))["status"]
            release_after_deadline && @test REPLy.session_state(session) === REPLy.SessionQuarantined
        end
    end

    @testset "quarantine operations do not wait on eval lock or task" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "locked")
        blocker = @async wait(Condition())
        life = REPLy.EvalLifecycle("locked-eval")
        lock(life.lock) do
            life.task = blocker
            life.state = REPLy.EvalRunning
            life.eval_id = 7
        end
        lock(session.lock) do
            session.state = REPLy.SessionQuarantined
            session.eval_task = blocker
            session.running_lifecycle = life
            session.eval_id = 7
        end
        held = Channel{Nothing}(1); unlock = Channel{Nothing}(1)
        holder = Threads.@spawn lock(session.eval_lock) do; put!(held, nothing); take!(unlock); end
        take!(held)
        handler = REPLy.build_handler(; manager)
        for request in (Dict("op" => "eval", "id" => "q-e", "session" => "locked", "code" => "1"),
                        Dict("op" => "stdin", "id" => "q-s", "session" => "locked", "input" => "x"))
            response = @async handler(request)
            @test timedwait(() -> istaskdone(response), 1.0) === :ok
            @test "session-quarantined" in last(fetch(response))["status"]
        end
        for _ in 1:2
            response = @async handler(Dict("op" => "interrupt", "id" => "q-i", "session" => "locked", "interrupt-id" => 8))
            @test timedwait(() -> istaskdone(response), 1.0) === :ok
            @test isempty(first(fetch(response))["interrupted"])
        end
        closed = @async handler(Dict("op" => "close", "id" => "q-c", "session" => "locked"))
        @test timedwait(() -> istaskdone(closed), 1.0) === :ok
        @test REPLy.session_state(session) === REPLy.SessionDetached
        put!(unlock, nothing); wait(holder)
        istaskdone(blocker) || schedule(blocker, InterruptException(); error=true)
    end

    @testset "ephemeral zombie retains all accounting and rejects queued and new" begin
        limits = REPLy.ResourceLimits(max_eval_time_ms=50, max_concurrent_evals=1, max_sessions=3)
        manager = REPLy.SessionManager(); state = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        release = Channel{Nothing}(1)
        @eval Main const REPLY_EPHEMERAL_ZOMBIE_RELEASE = $release
        handler = REPLy.build_handler(; manager, state)
        zombie = handler(Dict("op" => "eval", "id" => "ep-z", "timeout-ms" => 50,
            "code" => "hold() = try; take!(Main.REPLY_EPHEMERAL_ZOMBIE_RELEASE); catch; hold(); end; hold()"))
        @test "timeout" in last(zombie)["status"]
        @test REPLy.active_count(state.gate) == 1
        @test length(REPLy.active_eval_tasks(state)) == 1
        @test REPLy.total_session_count(manager) == 1
        for id in ("new-1", "new-2")
            rejected = @async handler(Dict("op" => "eval", "id" => id, "code" => "1"))
            @test timedwait(() -> istaskdone(rejected), 1.0) === :ok
            @test "concurrency-limit-reached" in last(fetch(rejected))["status"]
        end
        put!(release, nothing)
        @test timedwait(() -> REPLy.active_count(state.gate) == 0 && REPLy.total_session_count(manager) == 0, 2.0) === :ok
        @test isempty(REPLy.active_eval_tasks(state))
    end

    @testset "schedule failure releases its own admission" begin
        limits = REPLy.ResourceLimits(max_concurrent_evals=1)
        state = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        manager = REPLy.SessionManager()
        original = REPLy._EVAL_TASK_SCHEDULER[]
        REPLy._EVAL_TASK_SCHEDULER[] = _ -> error("injected schedule failure")
        try
            @test_throws ErrorException REPLy.build_handler(; manager, state)(
                Dict("op" => "eval", "id" => "schedule-fail", "code" => "1"))
        finally
            REPLy._EVAL_TASK_SCHEDULER[] = original
        end
        @test REPLy.active_count(state.gate) == 0
        @test isempty(REPLy.active_eval_tasks(state))
    end

    @testset "shutdown closes registration race" begin
        limits = REPLy.ResourceLimits(max_concurrent_evals=1)
        state = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        REPLy.begin_shutdown!(state)
        msgs = REPLy.build_handler(; state)(Dict("op" => "eval", "id" => "late", "code" => "1"))
        @test "shutdown" in last(msgs)["status"]
        @test REPLy.active_count(state.gate) == 0
        @test isempty(REPLy.active_eval_tasks(state))
    end

    @testset "shutdown rejects gate waiters without registration or permit leaks" begin
        limits = REPLy.ResourceLimits(max_concurrent_evals=1)
        state = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        @test REPLy.acquire!(state.gate)
        queued = @async REPLy.build_handler(; state)(
            Dict("op" => "eval", "id" => "queued-shutdown", "code" => "1"))
        @test timedwait(() -> length(state.gate.queue) == 1, 1.0) === :ok

        @test isempty(REPLy.begin_shutdown!(state))

        @test timedwait(() -> istaskdone(queued), 1.0) === :ok
        @test "shutdown" in last(fetch(queued))["status"]
        @test isempty(state.gate.queue)
        @test isempty(REPLy.active_eval_tasks(state))
        REPLy.release!(state.gate)
        @test REPLy.active_count(state.gate) == 0
        @test isempty(REPLy.begin_shutdown!(state))
    end

    @testset "timed-out queued named eval cannot strand its successor" begin
        limits = REPLy.ResourceLimits(max_concurrent_evals=3)
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "queue-timeout")
        entered = Channel{Nothing}(1); release = Channel{Nothing}(1); executed = Channel{Nothing}(1)
        Core.eval(REPLy.session_module(session), :(entered = $entered; release = $release; executed = $executed))
        handler = REPLy.build_handler(; manager, state=REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES))
        running = @async handler(Dict("op" => "eval", "id" => "running", "session" => "queue-timeout",
            "code" => "put!(entered, nothing); take!(release); :running"))
        take!(entered)
        timed_out = @async handler(Dict("op" => "eval", "id" => "queued-timeout", "session" => "queue-timeout",
            "timeout-ms" => 300, "code" => "put!(executed, nothing); :never"))
        @test timedwait(() -> length(session.eval_queue) == 1, 1.0) === :ok
        successor = @async handler(Dict("op" => "eval", "id" => "successor", "session" => "queue-timeout", "code" => ":successor"))
        @test timedwait(() -> length(session.eval_queue) == 2, 1.0) === :ok
        @test timedwait(() -> istaskdone(timed_out), 1.0) === :ok
        @test "timeout" in last(fetch(timed_out))["status"]
        @test !istaskdone(running)
        @test session.running_lifecycle !== nothing
        @test timedwait(() -> length(session.eval_queue) == 1, 1.0) === :ok
        @test !isready(executed)
        put!(release, nothing)
        @test timedwait(() -> istaskdone(running) && istaskdone(successor), 1.0) === :ok
        @test any(get(m, "value", nothing) == ":running" for m in fetch(running))
        @test any(get(m, "value", nothing) == ":successor" for m in fetch(successor))
        @test !isready(executed)
        @test isempty(session.eval_queue)
    end

    @testset "completion during timeout setup cannot strand observer cleanup" begin
        limits = REPLy.ResourceLimits(max_eval_time_ms=30, max_concurrent_evals=1)
        state = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        release = Channel{Nothing}(1); setup_entered = Channel{Nothing}(1); finish_setup = Channel{Nothing}(1)
        @eval Main const REPLY_SETUP_RELEASE = $release
        original = REPLy._TIMEOUT_SETUP_HOOK[]
        REPLy._TIMEOUT_SETUP_HOOK[] = () -> (put!(setup_entered, nothing); take!(finish_setup))
        try
            response = @async REPLy.build_handler(; state)(Dict("op" => "eval", "id" => "setup-race",
                "code" => "try; take!(Main.REPLY_SETUP_RELEASE); catch; take!(Main.REPLY_SETUP_RELEASE); end; :done"))
            take!(setup_entered)
            put!(release, nothing)
            yield()
            put!(finish_setup, nothing)
            @test timedwait(() -> istaskdone(response), 1.0) === :ok
            @test "timeout" in last(fetch(response))["status"]
            @test timedwait(() -> isempty(REPLy.active_eval_tasks(state)) && REPLy.active_count(state.gate) == 0, 1.0) === :ok
        finally
            REPLy._TIMEOUT_SETUP_HOOK[] = original
        end
    end

    @testset "interrupt during timeout setup cannot consume timeout cancellation" begin
        limits = REPLy.ResourceLimits(max_eval_time_ms=30, max_concurrent_evals=1)
        state = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "setup-interrupt")
        blocker = Channel{Nothing}(1); setup_entered = Channel{Nothing}(1); finish_setup = Channel{Nothing}(1)
        Core.eval(REPLy.session_module(session), :(blocker = $blocker))
        original = REPLy._TIMEOUT_SETUP_HOOK[]
        REPLy._TIMEOUT_SETUP_HOOK[] = () -> (put!(setup_entered, nothing); take!(finish_setup))
        handler = REPLy.build_handler(; manager, state)
        try
            response = @async handler(Dict("op" => "eval", "id" => "setup-interrupt-eval",
                "session" => "setup-interrupt", "code" => "take!(blocker)"))
            take!(setup_entered)
            interrupted = handler(Dict("op" => "interrupt", "id" => "setup-interrupt-request",
                "session" => "setup-interrupt"))
            @test last(interrupted)["status"] == ["done"]
            @test !only(REPLy.active_eval_lifecycles(state)).cancel_requested
            put!(finish_setup, nothing)
            @test timedwait(() -> istaskdone(response), 1.0) === :ok
            @test "timeout" in last(fetch(response))["status"]
            @test timedwait(() -> isempty(REPLy.active_eval_tasks(state)) &&
                REPLy.active_count(state.gate) == 0, 1.0) === :ok
            @test REPLy.session_state(session) === REPLy.SessionQuarantined
            handler(Dict("op" => "close", "id" => "setup-interrupt-close", "session" => "setup-interrupt"))
            @test REPLy.total_session_count(manager) == 0
        finally
            REPLy._TIMEOUT_SETUP_HOOK[] = original
        end
    end

    @testset "timeout setup hook failure cannot bypass retention or gate cleanup" begin
        limits = REPLy.ResourceLimits(max_eval_time_ms=30, max_concurrent_evals=1)
        state = REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        manager = REPLy.SessionManager()
        release = Channel{Nothing}(1)
        @eval Main const REPLY_FAULT_RELEASE = $release
        original = REPLy._TIMEOUT_SETUP_HOOK[]
        REPLy._TIMEOUT_SETUP_HOOK[] = () -> error("injected timeout setup fault")
        try
            msgs = REPLy.build_handler(; manager, state)(Dict("op" => "eval", "id" => "setup-fault",
                "code" => "hold() = try; take!(Main.REPLY_FAULT_RELEASE); catch; hold(); end; hold()"))
            @test "timeout" in last(msgs)["status"]
            lives = REPLy.active_eval_lifecycles(state)
            @test length(lives) == 1
            @test only(lives).cancel_requested
            @test only(lives).ephemeral_retained
            @test only(lives).zombie_gate_marked
            @test REPLy.total_session_count(manager) == 1
            @test REPLy.active_count(state.gate) == 1
            put!(release, nothing)
            @test timedwait(() -> isempty(REPLy.active_eval_tasks(state)) &&
                REPLy.active_count(state.gate) == 0 && REPLy.total_session_count(manager) == 0, 2.0) === :ok
        finally
            REPLy._TIMEOUT_SETUP_HOOK[] = original
        end
    end
end
