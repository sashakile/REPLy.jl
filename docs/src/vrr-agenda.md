# Value Realization Review — Agenda Template
**VRR Date:** [YYYY-MM-DD]
**Reviewer:** [name]
**Prepared by:** [name]
## 1. Restate the Value Proposition
Read the canonical falsifiable VP aloud (from `docs/src/value-proposition.md`):
> REPLy.jl will enable **Julia tool builders** to **ship** **structured REPL interaction into their editors, IDEs, and MCP servers** by **cutting integration time from days to minutes** within **the first development session**, as measured by **time-to-first-successful-eval for a new client**, compared to **building directly on Sockets.jl or adapting RemoteREPL.jl**.
### Self-check
- [ ] Has the VP changed since last review? If yes, ALL three locations updated:
  - [ ] `docs/src/value-proposition.md`
  - [ ] `GOVERNANCE.md` §1
  - [ ] MCP adapter tool description (Goal Sandwich)
- [ ] If VP changed, eval suite re-run after update?
## 2. Evidence Review
### Behavioral Health (since last review)
| Metric | Current | Prior | Trend | Target |
|--------|---------|-------|-------|--------|
| Eval pass rate (CI) | | | | ≥95% |
| MCP adapter test pass rate | | | | 100% |
| Safety dispatch trigger count | | | | — |
| Scope violation count | | | | 0 |
| Open issue count | | | | — |
### Adoption Health (since last review)
| Metric | Current | Prior | Trend | Target |
|--------|---------|-------|-------|--------|
| GitHub stars | | | | Growing |
| External contributors | | | | ≥1 |
| Download count/week | | | | Growing |
| Downstream dependents | | | | ≥1 by v1.0 |
### Value Health (since last review)
| Metric | Current | Prior | Trend | Target |
|--------|---------|-------|-------|--------|
| Time-to-first-eval reference client | | | | <50ms p50 |
| Session creation latency | | | | <5ms p50 |
| Kill criteria triggered? | | | | No |
## 3. Gap Analysis
Compare evidence against VP targets:
| Gap | Severity | Root cause hypothesis | Action |
|-----|----------|----------------------|--------|
| | | | |
| | | | |
## 4. Continue / Pivot / Kill Decision
- **Continue** — evidence supports VP; maintain trajectory
- **Pivot** — VP needs adjustment (record new VP above); re-baseline
- **Kill** — evidence refutes VP; archive project
**Decision:** [Continue / Pivot / Kill]
**Rationale:** [2–3 sentences]
## 5. Updated Kill Criteria Review
| Criterion | Threshold | Current value | Status |
|-----------|-----------|---------------|--------|
| | | | ✅ on-track / ⚠️ at-risk / ❌ triggered |
## 6. Action Items
| Action | Owner | Due | Layer |
|--------|-------|-----|-------|
| | | | |
| | | | |
## 7. Next Review
**Next VRR scheduled:** [YYYY-MM-DD — 90 days from this review]
---
*Template version: 1.0. Last updated: 2026-08-01.*
