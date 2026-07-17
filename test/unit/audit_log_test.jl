using Dates
using UUIDs
using JSON3

@testset "Audit logging" begin
    make_entry(i; session_id=nothing, success=true, error=nothing) = REPLy.AuditLogEntry(
        timestamp=DateTime(2026, 4, 23, 12, 0, i),
        client_id=UUID("123e4567-e89b-12d3-a456-426614174000"),
        session_id=session_id,
        operation="op-$i",
        user="",
        source_ip="127.0.0.1",
        success=success,
        error=error,
    )

    @testset "entry shape is stable" begin
        entry = make_entry(1; session_id="named-1", success=false, error="boom")
        log = REPLy.AuditLog()

        REPLy.record_audit!(log, entry)
        entries = REPLy.audit_entries(log)

        @test length(entries) == 1
        @test entries[1].timestamp == DateTime(2026, 4, 23, 12, 0, 1)
        @test entries[1].client_id == UUID("123e4567-e89b-12d3-a456-426614174000")
        @test entries[1].session_id == "named-1"
        @test entries[1].operation == "op-1"
        @test entries[1].user == ""
        @test entries[1].source_ip == "127.0.0.1"
        @test entries[1].success === false
        @test entries[1].error == "boom"
    end

    @testset "constructor rejects invalid bounds" begin
        @test_throws ArgumentError REPLy.AuditLog(max_entries=0)
        @test_throws ArgumentError REPLy.AuditLog(evict_count=0)
        @test_throws ArgumentError REPLy.AuditLog(max_entries=5, evict_count=6)
        @test_throws ArgumentError REPLy.AuditLog(rotate_bytes=0)
    end

    @testset "bounded eviction drops oldest entries in chunks" begin
        log = REPLy.AuditLog(max_entries=5, evict_count=2)

        for i in 1:6
            REPLy.record_audit!(log, make_entry(i))
        end

        entries = REPLy.audit_entries(log)
        @test length(entries) == 4
        @test getfield.(entries, :operation) == ["op-3", "op-4", "op-5", "op-6"]
    end

    @testset "ndjson log rotates before exceeding size limit" begin
        mktempdir() do dir
            path = joinpath(dir, "audit.ndjson")
            log = REPLy.AuditLog(path=path, rotate_bytes=180)

            REPLy.record_audit!(log, make_entry(1))
            @test isfile(path)
            @test !isfile(path * ".1")

            REPLy.record_audit!(log, make_entry(2))
            @test isfile(path)
            @test isfile(path * ".1")

            current_lines = filter(!isempty, readlines(path))
            rotated_lines = filter(!isempty, readlines(path * ".1"))

            @test length(current_lines) == 1
            @test length(rotated_lines) == 1

            current = JSON3.read(only(current_lines))
            rotated = JSON3.read(only(rotated_lines))

            @test rotated["operation"] == "op-1"
            @test current["operation"] == "op-2"
            @test rotated["success"] === true
            @test current["success"] === true
        end
    end

    @testset "audit_entries is race-free under concurrent writes" begin
        log = REPLy.AuditLog(max_entries=10_000, evict_count=100)

        base_time = DateTime(2026, 4, 23, 12, 0, 0)

        # Writer task: continuously push entries into the audit log.
        writer = @task begin
            for i in 1:10_000
                entry = REPLy.AuditLogEntry(
                    timestamp=base_time + Millisecond(i),
                    client_id=UUID("123e4567-e89b-12d3-a456-426614174000"),
                    session_id=nothing,
                    operation="op-$i",
                    user="",
                    source_ip="127.0.0.1",
                    success=true,
                    error=nothing,
                )
                REPLy.record_audit!(log, entry)
            end
        end

        # Reader task: repeatedly snapshot the audit log while the
        # writer is running. Must never throw BoundsError or produce
        # a torn read.
        reader = @task begin
            for _ in 1:500
                entries = REPLy.audit_entries(log)
                # Snapshot must be internally consistent: no duplicate
                # timestamps from a torn read, and each entry must be
                # a valid AuditLogEntry (not a partially-constructed object).
                @test all(e -> e isa REPLy.AuditLogEntry, entries)
                # Within a snapshot, timestamps must be strictly increasing
                # (audit entries are appended, never reordered).
                for i in 2:length(entries)
                    @test entries[i].timestamp > entries[i-1].timestamp
                end
                yield()
            end
        end

        schedule(writer)
        schedule(reader)
        wait(writer)
        wait(reader)
    end
end
