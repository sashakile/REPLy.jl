<!-- vale off -->
# Development Methodology

This page explains how REPLy.jl uses AI-assisted development, which controls are
automated, and where the process has limits. It exists so users and contributors can
evaluate the project using inspectable evidence rather than broad assurances.

REPLy.jl is also an experiment: how far can a non-trivial codebase be pushed using
this Human–AI pair-programming workflow? Substantive features, defects, and
refactorings are tracked as [published bead tickets](https://charly-vibes.github.io/atril/?owner=sashakile&repo=REPLy.jl&branch=main&view=beads&mode=list),
with supporting specifications, research, tests, and review artifacts stored in the
repository when the scope warrants them.

**TL;DR:** AI agents help research, design, implement, test, review, and document
REPLy.jl. The maintainer directs the work, approves changes, and remains accountable
for releases. The project uses tracked specifications, tickets, automated tests, CI,
and structured review, but it has not received a professional security audit or a
human line-by-line review of the entire codebase.

---

## What "AI-assisted" Means Here

REPLy.jl is developed through a Human–AI pair-programming workflow where:

- **The human** (the maintainer, Sasha) defines goals, makes architectural decisions,
  reviews proposed outcomes, accepts or rejects recommendations, and is accountable
  for changes that enter the repository.
- **AI coding agents** perform bounded tasks such as research, implementation,
  testing, review, and documentation under repository instructions. Agent output is
  treated as a proposal to verify, not as independent authority.

The amount and kind of review scale with the change. Substantive code and design
changes receive more scrutiny than generated artifacts or routine configuration.

---

## What Users Can Rely On

- The repository publishes its source, specifications, issue history, tests, CI
  configuration, research, and review artifacts for inspection.
- Automated tests cover unit, integration, and end-to-end behavior. CI measures line
  coverage for each tested commit; consult the coverage result for the release commit
  rather than treating a percentage in prose as permanent.
- TCP access is unauthenticated and evaluation executes arbitrary Julia code. The
  security guidance and documented resource limits are operational requirements, not
  evidence of sandboxing.
- Automated review can find defects, but it does not replace an independent audit or
  guarantee correctness.

---

## The Development Pipeline

The project uses the following pipeline for substantive features and fixes. Small
documentation or configuration changes may use a reduced path appropriate to their
risk.

### 1. Research Phase

For a significant feature or fix, an AI agent may perform structured research:

- Scopes the problem, identifies constraints, and surveys existing solutions
- Records findings in a research document (stored in `.wai/` with full rationale)
- The maintainer can approve, redirect, or reject the resulting recommendation

*Example:* The [replyc distribution research](https://github.com/sashakile/REPLy.jl/blob/main/.wai/projects/replyc-distribution/research/2026-07-15-reply-jl-replyc-distribution-research-2026.md)
tested three approaches (juliac compilation, deps/build.jl, Comonicon.jl),
documented trade-offs, and the human selected the approach.

### 2. Design Phase

Architectural decisions are recorded explicitly when a change requires them:

- Designs are documented with rationale, alternatives considered, and non-goals
- The maintainer approves the design direction before implementation begins
- Key decisions are captured in `.wai/` for future reference

### 3. Specification Phase

System capabilities are defined in **OpenSpec** files, and capability-changing work
uses validated change proposals:

- `openspec/specs/` contains the canonical capability definitions (protocol, middleware,
  session management, transport, security, etc.)
- Specs include requirement IDs, cross-references, and priority classifications
- Changes to the system are proposed as OpenSpec change proposals with validation

### 4. Implementation Phase (TDD)

Behavioral changes follow **test-driven development**:

1. **Red**: Write a failing test that defines the desired behaviour
2. **Green**: Write the minimal code to make the test pass
3. **Refactor**: Clean up without changing behaviour

Tickets are scoped around red→green→refactor cycles, with behavior-preserving
refactoring kept separate from feature changes.

### 5. Review Phase

The project selects review passes according to the change's risk and scope:

| Review Pass | What it Checks |
|---|---|
| **Rule of 5** | Whole-codebase review: architecture, design, correctness, security, style |
| **Holistic Review** | Cross-cutting concerns: modularity, composability, invariants, failure handling, performance, formal verification readiness, test suite quality |
| **Adversarial Review** | Security vulnerabilities, edge cases, failure modes, deployment risks |
| **Documentation Review** | Accuracy, completeness, discoverability, AI-readiness |
| **UX/DX Review** | API ergonomics, CLI usability, documentation friction |

Reviews are conducted by AI agents operating under structured prompts (skills) with
specific evaluation criteria. Findings are reported to the maintainer, who decides
whether they require fixes, follow-up tickets, or no action. Not every change uses
every pass in the table.

### 6. Maintainer Approval

The maintainer is responsible for deciding what lands and what is released:

- Review findings are triaged and prioritized
- Change proposals are approved, revised, or rejected
- The maintainer makes the final call on design trade-offs (the documented research
  contains examples of the human pushing back on AI recommendations)

### 7. Quality Gates

The repository uses gates at different lifecycle points:

- **Pre-commit hooks** check repository hygiene, spelling, and selected prose
- **Pre-push hooks** run the Julia test suite when Julia or TOML files changed
- **`just check`** runs workflow linting, spelling and prose checks, tests, the TCP
  smoke test, and line coverage
- **GitHub Actions CI** runs on pushes and pull requests
- **Documenter** builds the documentation on pushes to `main` and pull requests

---

## Tooling

The development process is supported by this toolchain:

| Tool | Purpose |
|---|---|
| **[OpenSpec](https://openspec.dev/)** | Specification-driven development: capability specs, change proposals, validation |
| **[espectacular (ah)](https://github.com/charly-vibes/espectacular)** | Behavioral verification: spec-test correspondence, scenario stubs, drift signals |
| **[wai](https://github.com/charly-vibes/wai)** | Reasoning capture: research, design decisions, handoffs, session continuity |
| **[beads (bd)](https://github.com/gastownhall/beads)** | Issue tracking: tasks, bugs, dependencies, status tracking |
| **[dont](https://github.com/charly-vibes/dont)** | Claim tracking: epistemic discipline for grounded assertions, evidence lifecycle |
| **Coding agents** | Execute bounded research, implementation, documentation, and review tasks under repository instructions |
| **Skill system** | Structured prompts for specific tasks: code review, TDD, design review, security audit, etc. |
| **[pretender](https://github.com/charly-vibes/pretender)** | Structural quality checks: cyclomatic complexity, duplication detection, mutation testing |
| **just** | Lightweight automation: test, lint, check, smoke test |
| **GitHub Actions** | CI: automated testing, linting, coverage, and documentation builds |
| **prek** | Pre-commit hygiene and lint checks; conditional pre-push test gate |

---

## Evidence and Limitations

The pipeline is consistent but not infallible. Three caveats:

- **The pipeline has produced code with known defects.** The April 2026 holistic
  review identified 43 open issues across several root-cause clusters —
  enforcement-deferred configuration, security-by-opt-in defaults, and shared
  mutable state without lock discipline. The review demonstrated that the process
  can find problems, not that it prevents them. Many of those issues have since been
  addressed; current work is visible in the published issue tracker.
- **Automated reviews are not a human audit.** Multi-pass AI reviews catch
  structural and logical problems, but they do not substitute for a professional
  security audit conducted by a human expert.
- **Not every file receives line-by-line human scrutiny.** Boilerplate artifacts
  (auto-generated handoff templates, CI scaffolding, configuration files) may
  enter the repository without individual human review. All substantive code and
  design changes remain the maintainer's responsibility.

Publishing both the methodology and the known issues gives readers a more
actionable basis for evaluating the project than a blanket LLM-generated-code
warning ever could.

---

## Contributing

If you'd like to contribute to REPLy.jl within this methodology, start by
reading the workflow instructions in [`AGENTS.md`](https://github.com/sashakile/REPLy.jl/blob/main/AGENTS.md) (and the
[`CLAUDE.md`](https://github.com/sashakile/REPLy.jl/blob/main/CLAUDE.md) for agent configuration). Run `wai status` to see the
current project phase and `bd ready` to find available work items.

---

## Repository Tour

| Artifact | Location | What it Tells You |
|---|---|---|
| Capability specs | `openspec/specs/` | What the system should do, in detail |
| Change proposals | `openspec/changes/` | How specific features were designed and approved |
| Behavioral scenarios | `.espectacular/` | Spec-test correspondence stubs for each capability |
| Research & reasoning | `.wai/projects/` (active), `.wai/archives/` (completed) | Why decisions were made, trade-offs considered |
| Issue tracker | `.beads/issues.jsonl` | What work was done, what's pending |
| Handoffs | `.wai/*/handoffs/` | Session continuity, decisions made during implementation |
| Reviews | `.wai/*/research/` (review findings) | Multi-pass evaluation results |
| Claims & evidence | `.dont/` | Epistemic state: tracked assertions, doubts, verified claims |
| Quality thresholds | `pretender.toml` | Complexity, duplication, and mutation benchmarks |
| Ubiquitous language | `.wai/resources/ubiquitous-language/` | Project terminology and domain model |
| Evaluations | [`docs/evaluations/`](https://github.com/sashakile/REPLy.jl/tree/main/docs/evaluations) | Maintainer-directed QA, stress tests, UX reports, and release-readiness assessments |
| CI | `.github/workflows/ci.yml` | Automated quality gates |
<!-- vale on -->
