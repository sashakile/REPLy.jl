<!-- vale off -->
# Development Methodology

This page describes how REPLy.jl is built. It exists so that users, contributors, and
anyone evaluating the project can inspect the development practices for themselves.

REPLy.jl is also an experiment: how far can a non-trivial codebase be pushed using
this Human–AI pair-programming workflow? Every feature, defect, and refactoring is
tracked as a [published bead ticket](https://charly-vibes.github.io/atril/?owner=sashakile&repo=REPLy.jl&branch=main&view=beads&mode=list)
so the full lifecycle — from initial research through review to commit — is
inspectable.

**TL;DR:** REPLy.jl uses AI-assisted development. Every line of code
passes through specification-first design, test-driven implementation, automated
multi-agent review, and human approval before landing in `main`. The repo's warning
banner is deliberately conservative; the pipeline behind it is more structured than the banner alone suggests.

---

## What "AI-assisted" Means Here

REPLy.jl is developed through a Human–AI pair programming workflow where:

- **The human** (the maintainer, Sasha) defines goals, makes architectural decisions,
  reviews all output, pushes back on recommendations, and owns every line of code
  that enters the repository.
- **The AI** (a coding agent, currently pi) executes research, writes code under TDD
  discipline, runs reviews, and produces documentation — but never acts without
  human oversight. Every code change and design decision is reviewed by the human
  before it is committed.

The human is involved at every phase of the development cycle.

---

## The Development Pipeline

Each feature or fix passes through a formal pipeline before reaching `main`:

### 1. Research Phase

Before implementing a significant feature or fix, an AI agent performs structured
research:

- Scopes the problem, identifies constraints, and surveys existing solutions
- Records findings in a research document (stored in `.wai/` with full rationale)
- The human reviews the research and either approves, redirects, or rejects

*Example:* The [replyc distribution research](https://github.com/sashakile/REPLy.jl/blob/main/.wai/projects/replyc-distribution/research/2026-07-15-reply-jl-replyc-distribution-research-2026.md)
tested three approaches (juliac compilation, deps/build.jl, Comonicon.jl),
documented trade-offs, and the human selected the approach.

### 2. Design Phase

Architectural decisions are made explicitly:

- Designs are documented with rationale, alternatives considered, and non-goals
- The human approves the design before implementation begins
- Key decisions are captured in `.wai/` for future reference

### 3. Specification Phase

All capabilities are defined in **OpenSpec** files before implementation:

- `openspec/specs/` contains the canonical capability definitions (protocol, middleware,
  session management, transport, security, etc.)
- Specs include requirement IDs, cross-references, and priority classifications
- Changes to the system are proposed as OpenSpec change proposals with validation

### 4. Implementation Phase (TDD)

Code follows **test-driven development**:

1. **Red**: Write a failing test that defines the desired behaviour
2. **Green**: Write the minimal code to make the test pass
3. **Refactor**: Clean up without changing behaviour

Each ticket in the issue tracker maps to a single red→green→refactor cycle.
Refactoring tasks are separate tickets from feature tasks.

### 5. Review Phase

Every implementation passes through **multiple automated review passes** before
the human sees it:

| Review Pass | What it Checks |
|---|---|
| **Rule of 5** | Whole-codebase review: architecture, design, correctness, security, style |
| **Holistic Review** | Cross-cutting concerns: modularity, composability, invariants, failure handling, performance, formal verification readiness, test suite quality |
| **Adversarial Review** | Security vulnerabilities, edge cases, failure modes, deployment risks |
| **Documentation Review** | Accuracy, completeness, discoverability, AI-readiness |
| **UX/DX Review** | API ergonomics, CLI usability, documentation friction |

Reviews are conducted by AI agents operating under structured prompts (skills)
that enforce specific evaluation criteria. Findings are reported back to the
human, who triages them into actionable tickets.

### 6. Human Approval Gate

Nothing enters the repository without human review:

- The human reads review findings, decides which to act on, and assigns priorities
- The human approves or rejects each change proposal
- The human makes the final call on design trade-offs (the documented research
  contains examples of the human pushing back on AI recommendations)

### 7. Quality Gates

Before any code is committed:

- **Automated tests** run (`just test`) — approximately 95% coverage across unit,
  integration, and end-to-end layers (as reported by the test suite)
- **Linting** runs (`just lint`) — spelling (`typos`) and prose (`vale`) checks
- **Smoke tests** run (`just smoke-test`) — end-to-end TCP server validation
- **CI** runs on every push via GitHub Actions

---

## Tooling

The development process is supported by a toolchain that enforces discipline:

| Tool | Purpose |
|---|---|
| **[OpenSpec](https://openspec.dev/)** | Specification-driven development: capability specs, change proposals, validation |
| **[wai](https://github.com/charly-vibes/wai)** | Reasoning capture: research, design decisions, handoffs, session continuity |
| **[beads (bd)](https://github.com/gastownhall/beads)** | Issue tracking: tasks, bugs, dependencies, status tracking |
| **[pi](https://github.com/earendil-works/pi)** | Coding agent (the tool generating this documentation under human supervision): executes research, implementation, and reviews |
| **Skill system** | Structured prompts for specific tasks: code review, TDD, design review, security audit, etc. |
| **just** | Lightweight automation: test, lint, check, smoke test |
| **GitHub Actions** | CI: automated testing, linting, coverage |
| **prek** | Pre-push hooks: test gate, lint, formatting checks |

---

## What This Means for Users

### The code is tested but not manually audited

The project has approximately 95% automated test coverage (as reported by the test
suite), extensive CI, and multi-pass review by AI agents. However, it has **not**
had a professional manual security audit or a human code review of every line.
This is what the warning banner on the home page communicates.

### The code is reviewable

Every change is documented with research, design decisions, and review
findings (all stored in `.wai/` and `openspec/`). A reader can trace the
rationale behind any feature or fix by reading those artifacts. The project
is transparent about how it was built.

### Registration readiness

Based on the project's current practices, the following best-practice criteria for
responsible AI-assisted development are met:

- A human maintainer has full understanding of the generated code
- Code is tested and CI runs
- LLM-generated contributions are disclosed (this page is that disclosure)
- The human communicates their own thoughts, not LLM-generated ones

The current warning banner in the README and docs is a conservative disclosure.

---

## Limitations

The pipeline is consistent but not infallible. Three caveats:

- **The pipeline has produced code with known defects.** The April 2026 holistic
  review identified 43 open issues across several root-cause clusters —
  enforcement-deferred configuration, security-by-opt-in defaults, and shared
  mutable state without lock discipline. These issues were found *by* the review
  pipeline, which demonstrates the pipeline working (catching problems before they
  reach users), but they also show that the pipeline does not prevent every defect.
  Many of these issues have since been addressed; the open issues are tracked in
  `.beads/issues.jsonl`.
- **Automated reviews are not a human audit.** Multi-pass AI reviews catch
  structural and logical problems, but they do not substitute for a professional
  security audit conducted by a human expert.
- **Not every file receives line-by-line human scrutiny.** Boilerplate artifacts
  (auto-generated handoff templates, CI scaffolding, configuration files) may
  enter the repository without individual human review. All substantive code and
  design decisions are reviewed.

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
| Research & reasoning | `.wai/projects/` (active), `.wai/archives/` (completed) | Why decisions were made, trade-offs considered |
| Issue tracker | `.beads/issues.jsonl` | What work was done, what's pending |
| Handoffs | `.wai/*/handoffs/` | Session continuity, decisions made during implementation |
| Reviews | `.wai/*/research/` (review findings) | Multi-pass evaluation results |
| Ubiquitous language | `.wai/resources/ubiquitous-language/` | Project terminology and domain model |
| Evaluations | `docs/evaluations/` | Independent QA, stress tests, UX reports |
| CI | `.github/workflows/ci.yml` | Automated quality gates |
<!-- vale on -->
