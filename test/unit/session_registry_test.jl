@testset "named session registry" begin
    @testset "create_named_session! registers a session by name" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "myapp")
        @test REPLy.session_name(session) == "myapp"
        @test REPLy.session_module(session) isa Module
    end

    @testset "list_named_sessions returns all named sessions" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "alpha")
        REPLy.create_named_session!(manager, "beta")
        sessions = REPLy.list_named_sessions(manager)
        names = REPLy.session_name.(sessions)
        @test "alpha" in names
        @test "beta" in names
        @test length(sessions) == 2
    end

    @testset "lookup_named_session returns session by name" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "found")
        session = REPLy.lookup_named_session(manager, "found")
        @test session !== nothing
        @test REPLy.session_name(session) == "found"
    end

    @testset "lookup_named_session returns nothing for unknown name" begin
        manager = REPLy.SessionManager()
        @test REPLy.lookup_named_session(manager, "ghost") === nothing
    end

    @testset "destroy_named_session! removes session from registry" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "temp")
        REPLy.destroy_named_session!(manager, "temp")
        @test REPLy.lookup_named_session(manager, "temp") === nothing
        @test isempty(REPLy.list_named_sessions(manager))
    end

    @testset "destroy_named_session! is idempotent" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "temp")
        REPLy.destroy_named_session!(manager, "temp")
        REPLy.destroy_named_session!(manager, "temp")  # no error
        @test isempty(REPLy.list_named_sessions(manager))
    end

    @testset "named sessions have creation timestamp metadata" begin
        t_before = time()
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "dated")
        t_after = time()
        @test REPLy.session_created_at(session) >= t_before
        @test REPLy.session_created_at(session) <= t_after
    end

    @testset "named session isolates bindings from other named sessions" begin
        manager = REPLy.SessionManager()
        alpha = REPLy.create_named_session!(manager, "alpha")
        beta = REPLy.create_named_session!(manager, "beta")

        ma = REPLy.session_module(alpha)
        mb = REPLy.session_module(beta)
        @test ma !== mb

        Core.eval(ma, :(x = 100))
        Core.eval(mb, :(x = 200))
        @test Core.eval(ma, :x) == 100
        @test Core.eval(mb, :x) == 200
    end

    @testset "invariant: ephemeral sessions never appear in list_named_sessions" begin
        manager = REPLy.SessionManager()
        REPLy.create_ephemeral_session!(manager)
        REPLy.create_ephemeral_session!(manager)
        REPLy.create_named_session!(manager, "persistent")
        named = REPLy.list_named_sessions(manager)
        @test length(named) == 1
        @test REPLy.session_name(only(named)) == "persistent"
    end

    @testset "create_named_session! rejects duplicate alias" begin
        manager = REPLy.SessionManager()
        old = REPLy.create_named_session!(manager, "dup")

        @test_throws ArgumentError REPLy.create_named_session!(manager, "dup")

        # Original session is still registered and unmodified.
        found = REPLy.lookup_named_session(manager, "dup")
        @test found === old
        @test length(REPLy.list_named_sessions(manager)) == 1
    end

    @testset "clone_named_session! deep-copies mutable values" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "src")
        Core.eval(REPLy.session_module(source), :(arr = [1, 2, 3]))

        clone = REPLy.clone_named_session!(manager, "src", "dst")
        @test clone !== nothing

        # Mutate the array in the clone
        Core.eval(REPLy.session_module(clone), :(push!(arr, 4)))

        # Original must be unaffected
        @test Core.eval(REPLy.session_module(source), :arr) == [1, 2, 3]
        @test Core.eval(REPLy.session_module(clone), :arr) == [1, 2, 3, 4]
    end

    @testset "clone_named_session! throws when dest_name already exists" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "existing-src")
        REPLy.create_named_session!(manager, "existing-dst")

        @test_throws ArgumentError REPLy.clone_named_session!(manager, "existing-src", "existing-dst")
        # Both sessions should still be intact
        @test REPLy.lookup_named_session(manager, "existing-src") !== nothing
        @test REPLy.lookup_named_session(manager, "existing-dst") !== nothing
    end

    @testset "clone_named_session! skips Module-typed bindings without throwing" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "mod-src")
        # Bind a module into the session — deepcopy of Module throws, so this
        # exercises the skip guard.
        Core.eval(REPLy.session_module(source), :(import Base; m = Base))

        clone = REPLy.clone_named_session!(manager, "mod-src", "mod-dst")
        @test clone !== nothing
        # The Module binding is skipped, so it will be undefined in the clone.
        @test !isdefined(REPLy.session_module(clone), :m)
    end

    @testset "concurrent create and destroy do not corrupt state" begin
        manager = REPLy.SessionManager()
        n = 10
        tasks = [
            @async begin
                for i in 1:20
                    name = "concurrent-$(Threads.threadid())-$i"
                    REPLy.create_named_session!(manager, name)
                    REPLy.destroy_named_session!(manager, name)
                end
            end
            for _ in 1:n
        ]
        foreach(wait, tasks)
        # After all tasks complete, the registry should not contain any leftover entries
        # from this test (all were created and then destroyed).
        leftover = filter(s -> startswith(REPLy.session_name(s), "concurrent-"), REPLy.list_named_sessions(manager))
        @test isempty(leftover)
    end

    @testset "ephemeral session count unaffected by named sessions" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "named1")
        REPLy.create_named_session!(manager, "named2")
        ephemeral = REPLy.create_ephemeral_session!(manager)
        @test REPLy.session_count(manager) == 1  # only ephemeral
        REPLy.destroy_session!(manager, ephemeral)
        @test REPLy.session_count(manager) == 0
    end

    @testset "new named session starts in SessionIdle state" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-idle")
        @test REPLy.session_state(session) === REPLy.SessionIdle
    end

    @testset "new named session has no eval_task" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-task")
        @test REPLy.session_eval_task(session) === nothing
    end

    @testset "new named session has last_active_at near creation" begin
        t_before = time()
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-time")
        t_after = time()
        @test REPLy.session_last_active_at(session) >= t_before
        @test REPLy.session_last_active_at(session) <= t_after
    end

    @testset "transition_session_state! allows Idle→Running and Running→Idle" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-transition")
        REPLy.transition_session_state!(session, REPLy.SessionRunning)
        @test REPLy.session_state(session) === REPLy.SessionRunning
        REPLy.transition_session_state!(session, REPLy.SessionIdle)
        @test REPLy.session_state(session) === REPLy.SessionIdle
    end

    @testset "transition_session_state! rejects invalid edges including to/from SessionClosed" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-invalid")
        # Cannot go directly to SessionClosed via transition_session_state!
        @test_throws ArgumentError REPLy.transition_session_state!(session, REPLy.SessionClosed)
        # Cannot self-transition
        @test_throws ArgumentError REPLy.transition_session_state!(session, REPLy.SessionIdle)
        REPLy.transition_session_state!(session, REPLy.SessionRunning)
        @test_throws ArgumentError REPLy.transition_session_state!(session, REPLy.SessionRunning)
    end

    @testset "destroy_named_session! sets SessionClosed before removing from registry" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-destroy-closed")
        REPLy.destroy_named_session!(manager, "lifecycle-destroy-closed")
        @test REPLy.session_state(session) === REPLy.SessionClosed
        # Subsequent transition attempts from a destroyed session are rejected
        @test_throws ArgumentError REPLy.transition_session_state!(session, REPLy.SessionRunning)
    end

    @testset "begin_eval! atomically transitions to Running and assigns task" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-begin-eval")
        task = @async 42
        before = REPLy.session_last_active_at(session)
        sleep(0.01)
        REPLy.begin_eval!(session, task)
        @test REPLy.session_state(session) === REPLy.SessionRunning
        @test REPLy.session_eval_task(session) === task
        @test REPLy.session_last_active_at(session) > before
    end

    @testset "end_eval! atomically transitions to Idle and clears task" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-end-eval")
        task = @async 42
        REPLy.begin_eval!(session, task)
        REPLy.end_eval!(session)
        @test REPLy.session_state(session) === REPLy.SessionIdle
        @test REPLy.session_eval_task(session) === nothing
    end

    @testset "_record_activity! updates last_active_at" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-record-activity")
        before = REPLy.session_last_active_at(session)
        sleep(0.01)
        REPLy._record_activity!(session)
        @test REPLy.session_last_active_at(session) > before
    end

    @testset "concurrent field mutations do not corrupt state" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "lifecycle-concurrent")
        n = 20
        tasks = [
            @async begin
                for _ in 1:10
                    t = @async sleep(0)
                    REPLy.begin_eval!(session, t)
                    REPLy.end_eval!(session)
                end
            end
            for _ in 1:n
        ]
        foreach(wait, tasks)
        @test REPLy.session_state(session) === REPLy.SessionIdle
        @test REPLy.session_eval_task(session) === nothing
    end

    @testset "try_begin_eval! returns true and transitions when idle" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "try-begin-idle")
        task = @async sleep(0)
        result = REPLy.try_begin_eval!(session, task)
        @test result === true
        @test REPLy.session_state(session) === REPLy.SessionRunning
        REPLy.end_eval!(session)
    end

    @testset "try_begin_eval! returns false without throwing when session is closed" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "try-begin-closed")
        REPLy.destroy_named_session!(manager, "try-begin-closed")
        task = @async sleep(0)
        result = REPLy.try_begin_eval!(session, task)
        @test result === false
        @test REPLy.session_state(session) === REPLy.SessionClosed
    end

    @testset "try_begin_eval! throws ArgumentError when session is already running" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "try-begin-running")
        task1 = @async sleep(0)
        REPLy.begin_eval!(session, task1)
        task2 = @async sleep(0)
        @test_throws ArgumentError REPLy.try_begin_eval!(session, task2)
        REPLy.end_eval!(session)
    end

    @testset "try_begin_eval! is race-safe against concurrent destroy_named_session!" begin
        # Each task uses eval_lock (as production code does), so only one task calls
        # try_begin_eval! at a time. The race is between try_begin_eval! and the destroyer.
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "race-destroy")
        n = 20
        results = Channel{Bool}(n)
        tasks = [@async lock(session.eval_lock) do
                     t = @async sleep(0)
                     result = REPLy.try_begin_eval!(session, t)
                     put!(results, result)
                     result && REPLy.end_eval!(session)
                 end for _ in 1:n]
        destroyer = @async REPLy.destroy_named_session!(manager, "race-destroy")
        foreach(wait, tasks)
        wait(destroyer)
        close(results)
        outcomes = collect(results)
        @test length(outcomes) == n
        @test all(x -> x isa Bool, outcomes)  # no exceptions
        @test REPLy.session_state(session) === REPLy.SessionClosed
    end

    @testset "destroy_named_session! waits for in-flight eval before closing" begin
        # Regression: destroy used to set SessionClosed without acquiring eval_lock,
        # so a concurrent eval could call end_eval! on an already-closed session,
        # throwing ArgumentError in the finally block.
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "eval-in-flight")

        eval_holding = Channel{Nothing}(1)
        eval_release = Channel{Nothing}(1)

        # Hold eval_lock to simulate an in-flight eval.
        eval_task = @async lock(session.eval_lock) do
            put!(eval_holding, nothing)   # signal: lock is held
            take!(eval_release)           # wait for permission to finish
        end
        take!(eval_holding)  # wait until the simulated eval holds the lock

        # destroy should now block — it must acquire eval_lock first.
        destroy_task = @async REPLy.destroy_named_session!(manager, "eval-in-flight")

        # Give the destroy task a chance to reach the eval_lock acquisition.
        yield()

        # Session must still be in the registry — destroy has not completed.
        @test !isnothing(REPLy.lookup_named_session(manager, "eval-in-flight"))
        @test REPLy.session_state(session) !== REPLy.SessionClosed

        # Release the simulated eval; destroy should now proceed.
        put!(eval_release, nothing)
        wait(eval_task)

        result = fetch(destroy_task)
        @test result == true
        @test isnothing(REPLy.lookup_named_session(manager, "eval-in-flight"))
        @test REPLy.session_state(session) === REPLy.SessionClosed
    end
end

@testset "UUID session identity" begin
    @testset "create_named_session! assigns a UUID id" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "uuid-check")
        id = REPLy.session_id(session)
        @test id isa String
        @test length(id) == 36  # UUID format: 8-4-4-4-12
        @test occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", id)
    end

    @testset "each session gets a distinct UUID" begin
        manager = REPLy.SessionManager()
        s1 = REPLy.create_named_session!(manager, "id-s1")
        s2 = REPLy.create_named_session!(manager, "id-s2")
        @test REPLy.session_id(s1) != REPLy.session_id(s2)
    end

    @testset "lookup_named_session finds session by UUID" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "by-uuid")
        uuid = REPLy.session_id(session)
        found = REPLy.lookup_named_session(manager, uuid)
        @test !isnothing(found)
        @test found === session
    end

    @testset "lookup_named_session finds session by name alias" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "by-name")
        found = REPLy.lookup_named_session(manager, "by-name")
        @test !isnothing(found)
        @test found === session
    end

    @testset "lookup by UUID and by name return the same session" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "same-session")
        uuid = REPLy.session_id(session)
        @test REPLy.lookup_named_session(manager, uuid) === REPLy.lookup_named_session(manager, "same-session")
    end

    @testset "destroy_named_session! by UUID removes both UUID and alias entries" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "destroy-by-uuid")
        uuid = REPLy.session_id(session)
        REPLy.destroy_named_session!(manager, uuid)
        @test REPLy.lookup_named_session(manager, uuid) === nothing
        @test REPLy.lookup_named_session(manager, "destroy-by-uuid") === nothing
    end

    @testset "destroy_named_session! by name removes both UUID and alias entries" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "destroy-by-name")
        uuid = REPLy.session_id(session)
        REPLy.destroy_named_session!(manager, "destroy-by-name")
        @test REPLy.lookup_named_session(manager, uuid) === nothing
        @test REPLy.lookup_named_session(manager, "destroy-by-name") === nothing
    end

    @testset "session with empty name is still accessible by UUID" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "")
        uuid = REPLy.session_id(session)
        @test REPLy.session_name(session) == ""
        found = REPLy.lookup_named_session(manager, uuid)
        @test !isnothing(found)
        @test found === session
    end

    @testset "clone_named_session! assigns a new UUID to the clone" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "clone-uuid-src")
        clone = REPLy.clone_named_session!(manager, "clone-uuid-src", "clone-uuid-dst")
        @test !isnothing(clone)
        @test REPLy.session_id(clone) != REPLy.session_id(source)
        @test length(REPLy.session_id(clone)) == 36
    end

    @testset "clone_named_session! source can be referenced by UUID" begin
        manager = REPLy.SessionManager()
        source = REPLy.create_named_session!(manager, "clone-src-by-uuid")
        uuid = REPLy.session_id(source)
        Core.eval(REPLy.session_module(source), :(cloned_marker = :marker))

        clone = REPLy.clone_named_session!(manager, uuid, "clone-dst-from-uuid")
        @test !isnothing(clone)
        @test Core.eval(REPLy.session_module(clone), :cloned_marker) === :marker
    end
end

@testset "idle sweep" begin
    @testset "sweep_idle_sessions! removes sessions idle beyond threshold" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "old-session")
        REPLy.create_named_session!(manager, "fresh-session")

        old = REPLy.lookup_named_session(manager, "old-session")
        lock(old.lock) do; old.last_active_at = time() - 10.0; end

        removed = REPLy.sweep_idle_sessions!(manager; max_idle_seconds=5.0)
        @test Set(removed) == Set(["old-session"])
        @test isnothing(REPLy.lookup_named_session(manager, "old-session"))
        @test !isnothing(REPLy.lookup_named_session(manager, "fresh-session"))
    end

    @testset "sweep_idle_sessions! skips running sessions" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "running-session")

        # Back-date activity then use begin_eval! to mark as running (state machine API)
        task = @async sleep(0)
        REPLy.begin_eval!(session, task)
        lock(session.lock) do; session.last_active_at = time() - 10.0; end

        removed = REPLy.sweep_idle_sessions!(manager; max_idle_seconds=5.0)
        @test isempty(removed)
        @test !isnothing(REPLy.lookup_named_session(manager, "running-session"))
        REPLy.end_eval!(session)
    end

    @testset "sweep_idle_sessions! returns empty when all sessions are fresh" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "active-1")
        REPLy.create_named_session!(manager, "active-2")
        removed = REPLy.sweep_idle_sessions!(manager; max_idle_seconds=3600.0)
        @test isempty(removed)
        @test length(REPLy.list_named_sessions(manager)) == 2
    end

    @testset "sweep_idle_sessions! rejects non-positive max_idle_seconds" begin
        manager = REPLy.SessionManager()
        @test_throws ArgumentError REPLy.sweep_idle_sessions!(manager; max_idle_seconds=0.0)
        @test_throws ArgumentError REPLy.sweep_idle_sessions!(manager; max_idle_seconds=-1.0)
    end

    @testset "sweep_idle_sessions! does not destroy a concurrently-recreated session" begin
        manager = REPLy.SessionManager()
        REPLy.create_named_session!(manager, "recycled")
        old = REPLy.lookup_named_session(manager, "recycled")
        lock(old.lock) do; old.last_active_at = time() - 100.0; end

        # Recreate the session concurrently; sweep must not destroy the fresh one
        recreator = @async begin
            REPLy.destroy_named_session!(manager, "recycled")
            REPLy.create_named_session!(manager, "recycled")
        end

        removed = REPLy.sweep_idle_sessions!(manager; max_idle_seconds=5.0)
        wait(recreator)

        live = REPLy.lookup_named_session(manager, "recycled")
        if !isnothing(live)
            # If the fresh session survived, its state must not be Closed by the sweep
            @test REPLy.session_state(live) !== REPLy.SessionClosed
        end
        # At most one removal (the original session, not the fresh one)
        @test length(removed) <= 1
    end
end
