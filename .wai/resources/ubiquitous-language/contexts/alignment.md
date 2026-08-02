# Alignment Context
## One-line scope
Value alignment concepts: value proposition, goal anchoring, scope fencing, drift detection, and outcome verification — binding layer between governance decisions, runtime behavior, and verification.
## Core Concepts
| Term | Definition | Used where |
|------|------------|------------|
| **Value proposition** | Falsifiable statement of what the tool delivers, to whom, and how we know. | `docs/src/value-proposition.md` |
| **Primary objective** | Verbatim value proposition restated as a runtime instruction. | BSD §1, MCP tool descriptions, VRR agenda |
| **Goal sandwich** | Pattern: primary objective appears at the top *and* bottom of a system prompt/tool description to survive lost-in-the-middle. | `src/mcp/tools.jl` (julia_eval description) |
| **Scope fence** | Explicit negation of prohibited actions — what the tool MUST NOT do. | BSD §3, `src/mcp/server.jl` (safety dispatch) |
| **Escalation trigger** | Specific condition that forces stop-and-signal rather than silent proceed. 7 named triggers defined in BSD §4. | BSD §4, `src/mcp/server.jl` |
| **Minimal footprint** | Principle: do only what the request asks; no side-band or unexpected work. | BSD §5 (principles) |
| **Outcome achievement** | Whether the tool helped the user accomplish their *goal*, not just whether the code executed correctly. | `test/unit/mcp_value_alignment_test.jl` |
| **Behavioral regression** | A change (code, model, prompt) that breaks previously passing alignment behavior. | CI gates, BSD §9 |
| **Goal drift** | Gradual divergence of runtime behavior from the primary objective. | VRR, red-team reviews |
| **Value realization review (VRR)** | Quarterly ceremony: restate VP → review evidence → gap analysis → continue/pivot/kill. | `GOVERNANCE.md` §9 |
| **Decay detection** | Dashboard tiers (behavioral, adoption, value health) to detect drift before lagging metrics confirm it. | TBD — to be built |
## Term mapping (Integration)
| Concept | Governance term (BSD) | Runtime term (MCP tools) | Verification term (tests) |
|---------|----------------------|-------------------------|--------------------------|
| What the tool is for | Primary objective (BSD §1) | julia_eval description | goal_achievement check |
| What the tool must not do | Prohibited behaviors (§3) | Scope fence in input schema | scope_violation test case |
| When to stop and signal | Escalation triggers (§4) | Safety dispatch checks | escalation_trigger test case |
| Did the tool help | Success metrics (§6) | Value report (JSON) | outcome score |
| Behavior changed | Behavioral regression (§9) | — | Regression eval diff |
## Disambiguation
| Term | Meaning here | Confusable with |
|------|--------------|-----------------|
| **value** | Intended outcome for the user (Layer 1 sense) | `value` field in eval response (the REPL result) |
| **outcome** | Behavioral change in the user (outcome vs output) | "eval outcome" meaning the eval result |
| **goal** | The primary objective of the tool | "goal" in session management context is unrelated |
