using Dates
using UUIDs

@testset "AuditMiddleware" begin
    make_log() = REPLy.AuditLog()

    dummy_ctx() = REPLy.RequestContext(REPLy.SessionManager(), Dict{String, Any}[], nothing)

    @testset "records an entry for a handled op" begin
        log = make_log()
        mw = REPLy.AuditMiddleware(log)
        ctx = dummy_ctx()

        REPLy.handle_message(
            mw,
            Dict("op" => "eval", "id" => "a1"),
            _ -> Dict("id" => "a1", "status" => ["done"]),
            ctx,
        )

        entries = REPLy.audit_entries(log)
        @test length(entries) == 1
        @test entries[1].operation == "eval"
        @test entries[1].success === true
        @test isnothing(entries[1].error)
        @test entries[1].session_id === nothing
    end

    @testset "records success=false and error string when next throws" begin
        log = make_log()
        mw = REPLy.AuditMiddleware(log)
        ctx = dummy_ctx()

        @test_throws ErrorException REPLy.handle_message(
            mw,
            Dict("op" => "eval", "id" => "a2"),
            _ -> error("middleware exploded"),
            ctx,
        )

        entries = REPLy.audit_entries(log)
        @test length(entries) == 1
        @test entries[1].success === false
        @test !isnothing(entries[1].error)
        @test occursin("middleware exploded", entries[1].error)
    end

    @testset "captures session_id from NamedSession resolved by downstream middleware" begin
        log = make_log()
        mw = REPLy.AuditMiddleware(log)
        manager = REPLy.SessionManager()
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], nothing)

        named = REPLy.get_or_create_named_session!(manager, "mysession")

        REPLy.handle_message(
            mw,
            Dict("op" => "eval", "id" => "a3"),
            _ -> begin
                ctx.session = named
                Dict("id" => "a3", "status" => ["done"])
            end,
            ctx,
        )

        entries = REPLy.audit_entries(log)
        @test length(entries) == 1
        @test entries[1].session_id == REPLy.session_id(named)
    end

    @testset "session_id is nothing for ephemeral session" begin
        log = make_log()
        mw = REPLy.AuditMiddleware(log)
        manager = REPLy.SessionManager()
        ephemeral = REPLy.create_ephemeral_session!(manager)
        ctx = REPLy.RequestContext(manager, Dict{String, Any}[], ephemeral)

        REPLy.handle_message(
            mw,
            Dict("op" => "eval", "id" => "a4"),
            _ -> Dict("id" => "a4", "status" => ["done"]),
            ctx,
        )

        entries = REPLy.audit_entries(log)
        @test length(entries) == 1
        @test isnothing(entries[1].session_id)
    end

    @testset "passes message through to next unchanged" begin
        log = make_log()
        mw = REPLy.AuditMiddleware(log)
        ctx = dummy_ctx()
        received = Ref{Any}(nothing)

        REPLy.handle_message(
            mw,
            Dict("op" => "ping", "id" => "a5", "extra" => "data"),
            msg -> begin
                received[] = msg
                Dict("id" => "a5", "status" => ["done"])
            end,
            ctx,
        )

        @test received[]::Dict == Dict("op" => "ping", "id" => "a5", "extra" => "data")
    end

    @testset "returns next's result unmodified" begin
        log = make_log()
        mw = REPLy.AuditMiddleware(log)
        ctx = dummy_ctx()
        expected = Dict("id" => "a6", "status" => ["done"], "value" => "42")

        result = REPLy.handle_message(
            mw,
            Dict("op" => "eval", "id" => "a6"),
            _ -> expected,
            ctx,
        )

        @test result === expected
    end

    @testset "records one entry per request in a build_handler stack" begin
        log = make_log()
        manager = REPLy.SessionManager()
        handler = REPLy.build_handler(;
            manager=manager,
            middleware=REPLy.AbstractMiddleware[
                REPLy.AuditMiddleware(log),
                REPLy.default_middleware_stack()...,
            ],
        )

        handler(Dict("op" => "eval", "id" => "a7", "code" => "1 + 1"))
        handler(Dict("op" => "eval", "id" => "a8", "code" => "2 + 2"))

        entries = REPLy.audit_entries(log)
        @test length(entries) == 2
        @test all(e.operation == "eval" for e in entries)
        @test all(e.success === true for e in entries)
    end

    @testset "custom client_id and source_ip are recorded" begin
        client_id = UUID("aaaabbbb-cccc-dddd-eeee-ffffffffffff")
        log = make_log()
        mw = REPLy.AuditMiddleware(log; client_id=client_id, source_ip="10.0.0.1")
        ctx = dummy_ctx()

        REPLy.handle_message(
            mw,
            Dict("op" => "eval", "id" => "a9"),
            _ -> Dict("id" => "a9", "status" => ["done"]),
            ctx,
        )

        entries = REPLy.audit_entries(log)
        @test entries[1].client_id == client_id
        @test entries[1].source_ip == "10.0.0.1"
    end
end
