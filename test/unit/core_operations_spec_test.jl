# Purpose: Map the core-operations capability spec's scenarios to executable
#   assertions (openspec/specs/core-operations/spec.md, REPLy_jl-p695):
#   describe, eval (+ options: module routing, allow-stdin, timeout-ms,
#   silent, store-history, value truncation), load-file, interrupt,
#   complete, lookup, stdin, close, clone, ls-sessions, and the
#   unknown/malformed-operation fallbacks (REQ-RPL-010..020, 036, 037, 047i).
# Responsibilities:
#   - One testset per scenario id, named exactly like the scenario and the
#     contract TOML stem in .espectacular/core-operations/.
#   - Drive every scenario through the real middleware pipeline (build_handler)
#     or over a live TCP server via the shared helpers, so assertions cover
#     wire-visible behavior and fail loudly on regression.
# Rationale: The core-operations spec is the largest op-behavior contract;
#   keeping the mapping in one file makes spec-test correspondence auditable
#   via `ah check --run-tests`.
using Test
using REPLy
using Logging
using JSON3
using Sockets
using Dates
using UUIDs

@testset "core-operations spec adoption (REPLy_jl-p695)" begin

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    _terminal(msgs) = last(filter(m -> haskey(m, "status"), msgs))
    _value_msg(msgs) = first(filter(m -> haskey(m, "value"), msgs))
    _out_text(msgs) = join((m["out"] for m in msgs if haskey(m, "out")), "")

    function _handler(; limits=nothing, allow_load_file::Union{Nothing,Function}=nothing)
        manager = REPLy.SessionManager()
        state = isnothing(limits) ? nothing :
                REPLy.ServerState(limits, REPLy.DEFAULT_MAX_MESSAGE_BYTES)
        stack = REPLy.default_middleware_stack()
        if !isnothing(allow_load_file)
            stack = [mw isa REPLy.LoadFileMiddleware ?
                        REPLy.LoadFileMiddleware(; load_file_allowlist=allow_load_file) : mw
                     for mw in stack]
        end
        return REPLy.build_handler(; manager=manager, state=state, middleware=stack), manager
    end

    function _new_session(handler, id, name)
        msgs = handler(Dict("op" => "new-session", "id" => id, "name" => name))
        @test "done" in _terminal(msgs)["status"]
        return name
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-010 — describe Operation
    # -----------------------------------------------------------------------

    @testset "describe-response-shape" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict("op" => "describe", "id" => "d1"))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "d1")
                msg = only(msgs)
                ops = msg["ops"]
                for required in ["eval", "clone", "close", "complete", "lookup",
                                 "interrupt", "ls-sessions", "stdin", "load-file"]
                    @test haskey(ops, required)
                end
                eval_desc = ops["eval"]
                @test all(haskey(eval_desc, k) for k in ("doc", "requires", "optional", "returns"))
                @test haskey(msg["versions"], "julia")
                @test haskey(msg["versions"], "reply")
                @test "json" in msg["encodings-available"]
                @test msg["encoding-current"] == "json"
                @test msg["status"] == ["done"]
            finally
                close(sock)
            end
        end
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-011 — eval Operation
    # -----------------------------------------------------------------------

    @testset "successful-eval" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict("op" => "new-session", "id" => "se-boot", "name" => "se-s"))
                collect_until_done(sock)
                send_request(sock, Dict("op" => "eval", "id" => "se-1",
                                        "session" => "se-s", "code" => "1+1"))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "se-1")
                @test get(_value_msg(msgs), "value", nothing) == "2"
                @test haskey(_value_msg(msgs), "ns")
            finally
                close(sock)
            end
        end
    end

    @testset "eval-with-stdout" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                send_request(sock, Dict("op" => "new-session", "id" => "so-boot", "name" => "so-s"))
                collect_until_done(sock)
                send_request(sock, Dict("op" => "eval", "id" => "so-1",
                                        "session" => "so-s",
                                        "code" => "println(\"hello\")"))
                msgs = collect_until_done(sock)
                assert_conformance(msgs, "so-1")
                out_indexes = findall(m -> haskey(m, "out"), msgs)
                @test !isempty(out_indexes)
                @test occursin("hello\n", _out_text(msgs))
                # stdout precedes the value message
                @test maximum(out_indexes) < findfirst(m -> haskey(m, "value"), msgs)
            finally
                close(sock)
            end
        end
    end

    @testset "empty-code-returns-nothing" begin
        handler, manager = _handler()
        _new_session(handler, "ec-boot", "ec-s")
        msgs = handler(Dict("op" => "eval", "id" => "ec-1", "session" => "ec-s", "code" => ""))
        assert_conformance(msgs, "ec-1")
        @test get(_value_msg(msgs), "value", nothing) == "nothing"
        @test "done" in _terminal(msgs)["status"]
    end

    @testset "dotted-module-path-resolved" begin
        handler, manager = _handler()
        _new_session(handler, "dm-boot", "dm-s")
        Core.eval(Main, :(module COTop; module COInner; const CO_VAL = 77; end; end))
        # Module paths are rooted at unprotected top-level modules — Main/Base/Core
        # roots are blocked (PROTECTED_ROOT_MODULES), so the path omits the Main prefix.
        msgs = handler(Dict("op" => "eval", "id" => "dm-1", "session" => "dm-s",
                            "module" => "COTop.COInner", "code" => "string(CO_VAL)"))
        assert_conformance(msgs, "dm-1")
        @test get(_value_msg(msgs), "value", nothing) == "\"77\""
        # the eval ran in COTop.COInner, not the session module
        @test get(_value_msg(msgs), "ns", nothing) == "COInner"
    end

    @testset "unresolvable-module-returns-error" begin
        handler, manager = _handler()
        _new_session(handler, "um-boot", "um-s")
        msgs = handler(Dict("op" => "eval", "id" => "um-1", "session" => "um-s",
                            "module" => "Main.DoesNotExist", "code" => "1+1"))
        terminal = _terminal(msgs)
        @test "done" in terminal["status"]
        @test "error" in terminal["status"]
        @test startswith(get(terminal, "err", ""), "Cannot resolve module:")
    end

    @testset "allow-stdin-false-causes-eoferror" begin
        # Julia's readline() returns "" at EOF without raising; a byte-requiring
        # read is what observes the EOFError that devnull stdin raises
        # (same platform correction as REQ-RPL-073 in the protocol spec).
        handler, manager = _handler()
        _new_session(handler, "as-boot", "as-s")
        msgs = handler(Dict("op" => "eval", "id" => "as-1", "session" => "as-s",
                            "allow-stdin" => false, "code" => "read(stdin, UInt8)"))
        terminal = _terminal(msgs)
        @test "error" in terminal["status"]
        @test occursin("EOFError", get(terminal, "err", ""))
    end

    @testset "timeout-ms-below-1-rejected" begin
        handler, manager = _handler()
        _new_session(handler, "tb-boot", "tb-s")
        msgs = handler(Dict("op" => "eval", "id" => "tb-1", "session" => "tb-s",
                            "timeout-ms" => 0, "code" => "1"))
        terminal = _terminal(msgs)
        @test "error" in terminal["status"]
        @test occursin("timeout-ms must be ≥ 1", get(terminal, "err", ""))
    end

    @testset "timeout-ms-capped-at-max" begin
        limits = REPLy.ResourceLimits(max_eval_time_ms=300, max_concurrent_evals=10)
        handler, manager = _handler(; limits=limits)
        _new_session(handler, "tc-boot", "tc-s")
        msgs = handler(Dict("op" => "eval", "id" => "tc-1", "session" => "tc-s",
                            "timeout-ms" => 60_000, "code" => "sleep(600)"))
        terminal = last(msgs)
        # A 60 s per-request timeout must be capped to the 300 ms server max.
        @test "timeout" in terminal["status"]
        @test get(terminal, "max-eval-time-ms", nothing) == 300
    end

    @testset "silent-suppresses-value" begin
        handler, manager = _handler()
        _new_session(handler, "sv-boot", "sv-s")
        msgs = handler(Dict("op" => "eval", "id" => "sv-1", "session" => "sv-s",
                            "silent" => true, "code" => "println(\"si\"); 42"))
        @test isempty(filter(m -> haskey(m, "value"), msgs))
        @test occursin("si", _out_text(msgs))
        @test "done" in _terminal(msgs)["status"]
    end

    @testset "store-history-false-skips-ans" begin
        handler, manager = _handler()
        _new_session(handler, "sh-boot", "sh-s")
        msgs = handler(Dict("op" => "eval", "id" => "sh-1", "session" => "sh-s",
                            "store-history" => false, "code" => "shv = 21"))
        @test "done" in _terminal(msgs)["status"]
        # ans was not set by the store-history=false eval…
        msgs = handler(Dict("op" => "eval", "id" => "sh-2", "session" => "sh-s", "code" => "ans"))
        @test occursin("UndefVarError", get(_terminal(msgs), "err", ""))
        session = REPLy.lookup_named_session(manager, "sh-s")
        @test isempty(session.history)
        # …the binding itself is still live…
        msgs = handler(Dict("op" => "eval", "id" => "sh-3", "session" => "sh-s", "code" => "shv"))
        @test get(_value_msg(msgs), "value", nothing) == "21"
        # …and a default eval DOES update ans
        handler(Dict("op" => "eval", "id" => "sh-4", "session" => "sh-s", "code" => "22"))
        msgs = handler(Dict("op" => "eval", "id" => "sh-5", "session" => "sh-s", "code" => "ans"))
        @test get(_value_msg(msgs), "value", nothing) == "22"
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-047i — eval Value Truncation
    # -----------------------------------------------------------------------

    @testset "large-repr-truncated-with-flag" begin
        limits = REPLy.ResourceLimits(max_value_repr_bytes=100)
        handler, manager = _handler(; limits=limits)
        _new_session(handler, "tr-boot", "tr-s")
        msgs = handler(Dict("op" => "eval", "id" => "tr-1", "session" => "tr-s",
                            "code" => "repeat(\"x\", 1000)"))
        assert_conformance(msgs, "tr-1")
        @test endswith(get(_value_msg(msgs), "value", ""), "\n…[truncated to 100 bytes]")
        @test get(_terminal(msgs), "truncated", false) === true
        # small values are not truncated and carry no flag
        msgs = handler(Dict("op" => "eval", "id" => "tr-2", "session" => "tr-s", "code" => "42"))
        @test get(_value_msg(msgs), "value", nothing) == "42"
        @test !haskey(_terminal(msgs), "truncated")
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-013 — load-file Operation
    # -----------------------------------------------------------------------

    @testset "file-loaded-and-evaluated" begin
        handler, manager = _handler(; allow_load_file=_ -> true)
        _new_session(handler, "lf-boot", "lf-s")
        file = tempname() * ".jl"
        try
            write(file, "lf_check = 84")
            msgs = handler(Dict("op" => "load-file", "id" => "lf-1", "session" => "lf-s",
                                "file" => file))
            assert_conformance(msgs, "lf-1")
            @test get(_value_msg(msgs), "value", nothing) == "84"
            # the file's bindings live in the session module afterwards
            msgs = handler(Dict("op" => "eval", "id" => "lf-2", "session" => "lf-s",
                                "code" => "lf_check * 2"))
            @test get(_value_msg(msgs), "value", nothing) == "168"
        finally
            rm(file; force=true)
        end
    end

    @testset "path-allowlist-enforced" begin
        handler, manager = _handler(; allow_load_file=_ -> false)
        file = tempname() * ".jl"
        try
            write(file, "1 + 1")
            msgs = handler(Dict("op" => "load-file", "id" => "pa-1", "file" => file))
            terminal = _terminal(msgs)
            @test "done" in terminal["status"]
            @test "error" in terminal["status"]
            @test "path-not-allowed" in terminal["status"]
            @test occursin("Path not allowed", get(terminal, "err", ""))
        finally
            rm(file; force=true)
        end
    end

    @testset "unreadable-file-returns-error" begin
        handler, manager = _handler(; allow_load_file=_ -> true)
        msgs = handler(Dict("op" => "load-file", "id" => "ur-1",
                            "file" => "/nonexistent/core-ops-path/file.jl"))
        terminal = _terminal(msgs)
        @test "done" in terminal["status"]
        @test "error" in terminal["status"]
        @test "file-not-found" in terminal["status"]
        @test occursin("File not found", get(terminal, "err", ""))
        # no path leak in the classified error message
        @test !occursin("/nonexistent", get(terminal, "err", ""))
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-014 — interrupt Operation
    # -----------------------------------------------------------------------

    function _wait_running(manager, name; timeout=5.0)
        deadline = time() + timeout
        session = REPLy.lookup_named_session(manager, name)
        while REPLy.session_state(session) !== REPLy.SessionRunning
            yield()
            time() > deadline && error("timed out waiting for eval to start")
        end
        return session
    end

    @testset "interrupt-running-eval" begin
        handler, manager = _handler()
        _new_session(handler, "ir-boot", "ir-s")
        eval_done = Channel{Vector{Dict{String, Any}}}(1)
        @async begin
            msgs = handler(Dict("op" => "eval", "id" => "ir-1", "session" => "ir-s",
                                "code" => "sleep(30); 1"))
            put!(eval_done, msgs)
        end
        session = _wait_running(manager, "ir-s")
        eval_id = REPLy.session_eval_id(session)
        msgs = handler(Dict("op" => "interrupt", "id" => "ir-2", "session" => "ir-s",
                            "interrupt-id" => eval_id))
        @test [String(session.name)] == [String(n) for n in msgs[1]["interrupted"]]
        @test "done" in _terminal(msgs)["status"]
        # the targeted eval stream terminates with done+interrupted
        eval_msgs = timedwait(() -> isready(eval_done), 5.0) === :ok ? take!(eval_done) : nothing
        @test !isnothing(eval_msgs)
        @test ["done", "interrupted"] == String.(_terminal(eval_msgs)["status"])
    end

    @testset "interrupt-completed-eval-is-idempotent" begin
        handler, manager = _handler()
        _new_session(handler, "ic-boot", "ic-s")
        msgs = handler(Dict("op" => "eval", "id" => "ic-1", "session" => "ic-s", "code" => "1+1"))
        @test "done" in _terminal(msgs)["status"]
        completed_eval_id = REPLy.session_eval_id(REPLy.lookup_named_session(manager, "ic-s"))
        msgs = handler(Dict("op" => "interrupt", "id" => "ic-2", "session" => "ic-s",
                            "interrupt-id" => completed_eval_id))
        @test isempty(msgs[1]["interrupted"])
        @test _terminal(msgs)["status"] == ["done"]
    end

    @testset "interrupt-without-interrupt-id-cancels-all" begin
        handler, manager = _handler()
        _new_session(handler, "ia-boot", "ia-s")
        eval_done = Channel{Vector{Dict{String, Any}}}(1)
        @async begin
            msgs = handler(Dict("op" => "eval", "id" => "ia-1", "session" => "ia-s",
                                "code" => "sleep(30); 1"))
            put!(eval_done, msgs)
        end
        _wait_running(manager, "ia-s")
        msgs = handler(Dict("op" => "interrupt", "id" => "ia-2", "session" => "ia-s"))
        @test !isempty(msgs[1]["interrupted"])
        eval_msgs = timedwait(() -> isready(eval_done), 5.0) === :ok ? take!(eval_done) : nothing
        @test !isnothing(eval_msgs)
        @test "interrupted" in _terminal(eval_msgs)["status"]
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-015 — complete Operation
    # -----------------------------------------------------------------------

    @testset "completion-results-returned" begin
        handler, manager = _handler()
        msgs = handler(Dict("op" => "complete", "id" => "cr-1", "code" => "pri", "pos" => 3))
        assert_conformance(msgs, "cr-1")
        comp_msg = first(filter(m -> haskey(m, "completions"), msgs))
        completions = comp_msg["completions"]
        @test !isempty(completions)
        @test all(haskey(c, "text") && haskey(c, "type") for c in completions)
    end

    @testset "out-of-bounds-pos-returns-empty-completions" begin
        handler, manager = _handler()
        for bad_pos in (-1, 999)
            msgs = handler(Dict("op" => "complete", "id" => "ob-$bad_pos",
                                "code" => "pri", "pos" => bad_pos))
            comp_msg = first(filter(m -> haskey(m, "completions"), msgs))
            @test isempty(comp_msg["completions"])
            @test _terminal(msgs)["status"] == ["done"]
        end
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-016 — lookup Operation
    # -----------------------------------------------------------------------

    @testset "symbol-found" begin
        handler, manager = _handler()
        msgs = handler(Dict("op" => "lookup", "id" => "sf-1",
                            "symbol" => "println", "module" => "Base"))
        assert_conformance(msgs, "sf-1")
        msg = only(filter(m -> haskey(m, "found"), msgs))
        @test msg["found"] == true
        @test all(haskey(msg, k) for k in ("name", "type", "doc", "methods"))
        @test msg["name"] == "println"
    end

    @testset "symbol-not-found" begin
        handler, manager = _handler()
        msgs = handler(Dict("op" => "lookup", "id" => "sn-1",
                            "symbol" => "CO_MISSING_SYMBOL_XYZ", "module" => "Main"))
        msg = only(filter(m -> haskey(m, "found"), msgs))
        @test msg["found"] == false
        @test _terminal(msgs)["status"] == ["done"]
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-017 — stdin Operation
    # -----------------------------------------------------------------------

    @testset "input-unblocks-waiting-eval" begin
        handler, manager = _handler()
        _new_session(handler, "iu-boot", "iu-s")
        eval_done = Channel{Vector{Dict{String, Any}}}(1)
        @async begin
            msgs = handler(Dict("op" => "eval", "id" => "iu-1", "session" => "iu-s",
                                "code" => "readline()"))
            put!(eval_done, msgs)
        end
        _wait_running(manager, "iu-s")
        msgs = handler(Dict("op" => "stdin", "id" => "iu-2", "session" => "iu-s",
                            "input" => "ok\n"))
        @test msgs[1]["delivered"] == ["iu-s"]
        eval_msgs = timedwait(() -> isready(eval_done), 5.0) === :ok ? take!(eval_done) : nothing
        @test !isnothing(eval_msgs)
        @test get(_value_msg(eval_msgs), "value", nothing) == "\"ok\""
    end

    @testset "stdin-when-no-eval-blocked-buffers-input" begin
        handler, manager = _handler()
        _new_session(handler, "sb-boot", "sb-s")
        # Fill the bounded buffer (capacity max_stdin_buffer, default 16)…
        for i in 1:16
            msgs = handler(Dict("op" => "stdin", "id" => "sb-$i", "session" => "sb-s",
                                "input" => "line $i\n"))
            @test msgs[1]["buffered"] == ["sb-s"]
        end
        # …then one more: the oldest entry is dropped, not appended-after.
        msgs = handler(Dict("op" => "stdin", "id" => "sb-17", "session" => "sb-s",
                            "input" => "line 17\n"))
        @test msgs[1]["buffered"] == ["sb-s"]
        # A subsequent eval consumes from the front — "line 1" was dropped.
        msgs = handler(Dict("op" => "eval", "id" => "sb-18", "session" => "sb-s",
                            "code" => "readline()"))
        @test get(_value_msg(msgs), "value", nothing) == "\"line 2\""
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-018 — close Operation
    # -----------------------------------------------------------------------

    @testset "session-closed-successfully" begin
        handler, manager = _handler()
        _new_session(handler, "cs-boot", "cs-s")
        msgs = handler(Dict("op" => "close", "id" => "cs-1", "session" => "cs-s"))
        assert_conformance(msgs, "cs-1")
        @test _terminal(msgs)["status"] == ["done"]
        # the session is really gone
        msgs = handler(Dict("op" => "eval", "id" => "cs-2", "session" => "cs-s", "code" => "1"))
        @test "session-not-found" in _terminal(msgs)["status"]
    end

    @testset "close-unknown-session-returns-error" begin
        handler, manager = _handler()
        msgs = handler(Dict("op" => "close", "id" => "cu-1", "session" => "no-such-session"))
        terminal = _terminal(msgs)
        @test "done" in terminal["status"]
        @test "error" in terminal["status"]
        @test "session-not-found" in terminal["status"]
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-036 — clone Operation
    # -----------------------------------------------------------------------

    @testset "create-empty-session" begin
        handler, manager = _handler()
        # spec example sends neither session nor name
        msgs = handler(Dict("op" => "clone", "id" => "ce-1"))
        assert_conformance(msgs, "ce-1")
        new_session = msgs[1]["new-session"]
        @test UUID(new_session) isa UUID  # a fresh UUIDv4 session id
        # a parentless clone with an explicit name works too
        msgs = handler(Dict("op" => "clone", "id" => "ce-1b", "name" => "ce-named"))
        @test "done" in _terminal(msgs)["status"]
        # the cloned session is usable
        msgs = handler(Dict("op" => "eval", "id" => "ce-2", "session" => new_session,
                            "code" => "1+1"))
        @test get(_value_msg(msgs), "value", nothing) == "2"
    end

    @testset "clone-light-to-light-deep-copies-bindings" begin
        handler, manager = _handler()
        _new_session(handler, "cl-boot", "cl-parent")
        handler(Dict("op" => "eval", "id" => "cl-1", "session" => "cl-parent",
                     "code" => "cl_x = [1, 2, 3]"))
        msgs = handler(Dict("op" => "clone", "id" => "cl-2", "session" => "cl-parent",
                            "name" => "cl-child"))
        child = msgs[1]["new-session"]
        # child observes the copied bindings
        msgs = handler(Dict("op" => "eval", "id" => "cl-3", "session" => child,
                            "code" => "cl_x"))
        @test get(_value_msg(msgs), "value", nothing) == "[1, 2, 3]"
        # the copy is deep: mutating the child does not touch the parent
        handler(Dict("op" => "eval", "id" => "cl-4", "session" => child,
                     "code" => "push!(cl_x, 4)"))
        msgs = handler(Dict("op" => "eval", "id" => "cl-5", "session" => "cl-parent",
                            "code" => "cl_x"))
        @test get(_value_msg(msgs), "value", nothing) == "[1, 2, 3]"
    end

    @testset "non-serializable-bindings-skipped-with-warning" begin
        mutable struct CloneBomb end
        Base.deepcopy_internal(::CloneBomb, ::IdDict) = error("cannot deepcopy CloneBomb")

        handler, manager = _handler()
        _new_session(handler, "nb-boot", "nb-parent")
        session = REPLy.lookup_named_session(manager, "nb-parent")
        Core.eval(REPLy.session_module(session), :(nb_bomb = $(CloneBomb())))
        Core.eval(REPLy.session_module(session), :(nb_keep = 7))

        msgs = handler(Dict("op" => "clone", "id" => "nb-1", "session" => "nb-parent",
                            "name" => "nb-child"))
        assert_conformance(msgs, "nb-1")
        child = first(filter(m -> haskey(m, "new-session"), msgs))["new-session"]
        # a warning naming the skipped binding was emitted as an out chunk
        @test occursin("nb_bomb", _out_text(msgs))
        # the copyable binding still arrived, the bomb was skipped
        msgs = handler(Dict("op" => "eval", "id" => "nb-2", "session" => child,
                            "code" => "nb_keep"))
        @test get(_value_msg(msgs), "value", nothing) == "7"
        msgs = handler(Dict("op" => "eval", "id" => "nb-3", "session" => child,
                            "code" => "nb_bomb"))
        @test occursin("UndefVarError", get(_terminal(msgs), "err", ""))
    end

    @testset "heavy-clone-rejected-without-malt-jl" begin
        handler, manager = _handler()
        _new_session(handler, "hv-boot", "hv-parent")
        msgs = handler(Dict("op" => "clone", "id" => "hv-1", "session" => "hv-parent",
                            "name" => "hv-heavy", "type" => "heavy"))
        terminal = _terminal(msgs)
        @test terminal["status"] == ["done", "error"]
        @test get(terminal, "err", "") == "Heavy sessions require Malt.jl"
        # no destination was created
        msgs = handler(Dict("op" => "eval", "id" => "hv-2", "session" => "hv-heavy",
                            "code" => "1"))
        @test "session-not-found" in _terminal(msgs)["status"]
    end

    @testset "clone-to-existing-session-rejected" begin
        handler, manager = _handler()
        _new_session(handler, "cx-boot", "cx-parent")
        _new_session(handler, "cx-boot-2", "cx-taken")
        msgs = handler(Dict("op" => "clone", "id" => "cx-1", "session" => "cx-parent",
                            "name" => "cx-taken"))
        terminal = _terminal(msgs)
        @test "session-already-exists" in terminal["status"]
        @test occursin("Session already exists", get(terminal, "err", ""))
    end

    @testset "clone-during-in-flight-eval-waits-for-eval-mutex" begin
        handler, manager = _handler()
        _new_session(handler, "cm-boot", "cm-parent")
        eval_done = Channel{Vector{Dict{String, Any}}}(1)
        @async begin
            msgs = handler(Dict("op" => "eval", "id" => "cm-1", "session" => "cm-parent",
                                "code" => "sleep(1.0); cm_late = 99; nothing"))
            put!(eval_done, msgs)
        end
        _wait_running(manager, "cm-parent")
        clone_task = @async handler(Dict("op" => "clone", "id" => "cm-2",
                                         "session" => "cm-parent", "name" => "cm-child"))
        # the eval is still running: the clone must be waiting, not copying yet
        sleep(0.3)
        @test !istaskdone(clone_task)
        eval_msgs = take!(eval_done)
        @test "done" in _terminal(eval_msgs)["status"]
        clone_msgs = fetch(clone_task)
        assert_conformance(clone_msgs, "cm-2")
        child = clone_msgs[1]["new-session"]
        # the binding assigned at the END of the eval is visible to the clone —
        # the copy happened after the eval completed, not concurrently
        msgs = handler(Dict("op" => "eval", "id" => "cm-3", "session" => child,
                            "code" => "cm_late"))
        @test get(_value_msg(msgs), "value", nothing) == "99"
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-037 — ls-sessions Operation
    # -----------------------------------------------------------------------

    @testset "sessions-listed-with-metadata" begin
        handler, manager = _handler()
        _new_session(handler, "ls-boot", "ls-alpha")
        _new_session(handler, "ls-boot-2", "ls-beta")
        msgs = handler(Dict("op" => "ls-sessions", "id" => "ls-1"))
        assert_conformance(msgs, "ls-1")
        sessions_msg = first(filter(m -> haskey(m, "sessions"), msgs))
        sessions = sessions_msg["sessions"]
        @test length(sessions) == 2
        names = [String(s["name"]) for s in sessions]
        @test "ls-alpha" in names
        @test "ls-beta" in names
        for s in sessions
            @test haskey(s, "session")  # UUID id key
            @test haskey(s, "type")
            @test haskey(s, "created")
            @test haskey(s, "last-activity")
        end
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-019 — Unknown Operation Fallback
    # -----------------------------------------------------------------------

    @testset "unknown-op-returns-unknown-op-status" begin
        handler, manager = _handler()
        msgs = handler(Dict("op" => "frobnicate", "id" => "uo-1"))
        terminal = _terminal(msgs)
        @test "unknown-op" in terminal["status"]
        @test get(terminal, "err", "") == "Unknown operation: frobnicate"
    end

    # -----------------------------------------------------------------------
    # REQ-RPL-020 — Malformed Input Handling
    # -----------------------------------------------------------------------

    @testset "invalid-json-response" begin
        with_server(port=0) do handle
            sock = connect(handle.port)
            try
                write(sock, "{\"op\":\"eval\",\"id\":}\n")
                flush(sock)
                # no response bytes for the unparsable line, and the
                # connection stays open — a valid request is still served
                write(sock, "{\"id\":\"iv-1\",\"op\":\"no-such-op\"}\n")
                flush(sock)
                msgs = collect_until_done(sock; timeout_s=5.0)
                @test length(msgs) == 1
                @test "unknown-op" in msgs[1]["status"]
            finally
                close(sock)
            end
        end
    end

    @testset "missing-op-returns-error" begin
        handler, manager = _handler()
        msgs = handler(Dict("id" => "mo-1", "code" => "1+1"))
        terminal = _terminal(msgs)
        @test terminal["status"] == ["done", "error"]
        @test get(terminal, "err", "") == "op is required"
    end

    @testset "missing-id-returns-validation-error" begin
        handler, manager = _handler()
        msgs = handler(Dict("op" => "eval", "code" => "1+1"))
        terminal = _terminal(msgs)
        # no eval ran: without a request id nothing can be correlated
        @test get(terminal, "id", nothing) == ""
        @test terminal["status"] == ["done", "error"]
        @test get(terminal, "err", "") == "id must not be empty"
    end
end
