# REPLy.jl Value Proposition
> **Status:** Active — established 2026-08-01
> **Review cadence:** Quarterly
## Falsifiable Statement
> REPLy.jl will enable **Julia tool builders** to **ship** **structured REPL interaction into their editors, IDEs, and MCP servers** by **cutting integration time from days to minutes** within **the first development session**, as measured by **time-to-first-successful-eval for a new client**, compared to **building directly on Sockets.jl or adapting RemoteREPL.jl**.
### Slot Reference
| Slot | Value |
|------|-------|
| Tool | REPLy.jl |
| User segment | Julia tool builders (IDE/MCP server developers) |
| Outcome verb | ship |
| Outcome object | structured REPL interaction into editors, IDEs, MCP servers |
| Amount | cutting integration time from days to minutes |
| Time span | within the first development session |
| Metric | time-to-first-successful-eval for a new client |
| Baseline | building directly on Sockets.jl or adapting RemoteREPL.jl |
## Falsifiability Test
This proposition fails if any of the following is true:
1. A new client takes ≥2 hours to get a successful eval (the "days to minutes" claim is false).
2. The only adopters are the owner's own tools (segment too narrow — "tool builders" must include external contributors).
3. Adopters report that using REPLy added more complexity than building directly on Sockets.jl.
## Leading Indicators (tracked monthly)
| Indicator | What it predicts | Current |
|---|---|---|
| GitHub stars/week | Awareness in target segment | TBD |
| PRs from external contributors | Actual tool-builder adoption | TBD |
| CI eval pass rate | Behavioral health → value delivery | 100% (last run) |
## Lagging Indicators (tracked quarterly)
| Indicator | Target | Current |
|---|---|---|
| External tool builder adopters (downstream dependents) | ≥1 external tool built on REPLy | 0 |
| Time-to-first-eval for `replyc` CLI (reference client) | <1 second on reference hardware | TBD |
| Download count (semantic version releases) | Growing quarter-over-quarter | TBD |
## Outcome vs. Output
| Category | Definition |
|----------|------------|
| **Output** | What was built — protocol operations implemented, test coverage, release cadence |
| **Outcome** | What changed in user behavior — tool builders shipping working integrations |
| **Impact** | What changed at the ecosystem level — Julia tooling fragmentation reduced; nREPL-equivalent protocol exists for Julia |
The project must track outputs but make decisions based on outcomes and impact.
