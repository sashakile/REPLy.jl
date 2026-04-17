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
