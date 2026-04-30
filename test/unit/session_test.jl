@testset "ephemeral session manager" begin
    @testset "tracks ephemeral lifecycle for leak detection" begin
        manager = REPLy.SessionManager()
        @test REPLy.session_count(manager) == 0

        session = REPLy.create_ephemeral_session!(manager)
        @test REPLy.session_count(manager) == 1
        @test REPLy.session_module(session) isa Module

        REPLy.destroy_session!(manager, session)
        @test REPLy.session_count(manager) == 0
    end

    @testset "destroying one session preserves the others" begin
        manager = REPLy.SessionManager()
        first = REPLy.create_ephemeral_session!(manager)
        second = REPLy.create_ephemeral_session!(manager)

        @test REPLy.session_count(manager) == 2

        REPLy.destroy_session!(manager, first)
        @test REPLy.session_count(manager) == 1
        @test Core.eval(REPLy.session_module(second), :(40 + 2)) == 42

        REPLy.destroy_session!(manager, second)
        @test REPLy.session_count(manager) == 0
    end

    @testset "destroy is idempotent" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_ephemeral_session!(manager)

        REPLy.destroy_session!(manager, session)
        REPLy.destroy_session!(manager, session)

        @test REPLy.session_count(manager) == 0
    end

    @testset "tracks multiple ephemeral sessions" begin
        manager = REPLy.SessionManager()
        sessions = [REPLy.create_ephemeral_session!(manager) for _ in 1:5]

        @test REPLy.session_count(manager) == 5
        @test length(unique(REPLy.session_module.(sessions))) == 5

        foreach(session -> REPLy.destroy_session!(manager, session), sessions)
        @test REPLy.session_count(manager) == 0
    end

    @testset "isolates bindings across anonymous modules" begin
        manager = REPLy.SessionManager()
        first = REPLy.create_ephemeral_session!(manager)
        second = REPLy.create_ephemeral_session!(manager)

        first_module = REPLy.session_module(first)
        second_module = REPLy.session_module(second)

        @test first_module !== second_module

        Core.eval(first_module, :(x = 41))
        Core.eval(second_module, :(x = 1))

        @test Core.eval(first_module, :x) == 41
        @test Core.eval(second_module, :x) == 1

        REPLy.destroy_session!(manager, first)
        REPLy.destroy_session!(manager, second)
        @test REPLy.session_count(manager) == 0
    end
end

@testset "stdin_channel is bounded (not infinite capacity)" begin
    @test REPLy.MAX_STDIN_BUFFER_SIZE == 256
    session = REPLy.NamedSession("id1", "bounded-test", Module())
    # Fill the channel to capacity to verify it's bounded
    for i in 1:REPLy.MAX_STDIN_BUFFER_SIZE
        put!(session.stdin_channel, "line $i")
    end
    # Verify all items are buffered and the channel is at capacity
    @test Base.n_avail(session.stdin_channel) == REPLy.MAX_STDIN_BUFFER_SIZE
end

@testset "NamedSession eval_id" begin
    @testset "new session starts with eval_id == 0" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "eval-id-init")
        @test REPLy.session_eval_id(session) == 0
    end

    @testset "begin_eval! increments eval_id" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "eval-id-incr")

        @test REPLy.session_eval_id(session) == 0
        REPLy.begin_eval!(session, current_task())
        @test REPLy.session_eval_id(session) == 1
        REPLy.end_eval!(session)

        REPLy.begin_eval!(session, current_task())
        @test REPLy.session_eval_id(session) == 2
        REPLy.end_eval!(session)
    end

    @testset "eval_id is independent across sessions" begin
        manager = REPLy.SessionManager()
        s1 = REPLy.create_named_session!(manager, "eval-id-ind-1")
        s2 = REPLy.create_named_session!(manager, "eval-id-ind-2")

        REPLy.begin_eval!(s1, current_task())
        REPLy.end_eval!(s1)
        REPLy.begin_eval!(s1, current_task())
        REPLy.end_eval!(s1)

        @test REPLy.session_eval_id(s1) == 2
        @test REPLy.session_eval_id(s2) == 0
    end

    @testset "try_begin_eval! also increments eval_id" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "eval-id-try-begin")

        result = REPLy.try_begin_eval!(session, current_task())
        @test result == true
        @test REPLy.session_eval_id(session) == 1
        REPLy.end_eval!(session)
    end
end
