<!-- WAI:START -->
# Workflow Tools

This project uses **wai** to track the *why* behind decisions — research,
reasoning, and design choices that shaped the code. Run `wai status` first
to orient yourself.
> **Ro5**: The Rule of 5 skill is installed. Run `/ro5` after key phase transitions — implement, research, design — for iterative quality review.

## Starting a Session

1. Run `wai status` to see active projects, current phase, and suggestions.
2. Check the phase — it tells you what kind of work is expected:
   - **research** → gather information, explore options
   - **design** → make architectural decisions
   - **plan** → break work into tasks
   - **implement** → write code, guided by research/plans
   - **review** → validate against plans
   - **archive** → wrap up
3. Read existing artifacts with `wai search "<topic>"` before starting new work.

## Capturing Work

Record the reasoning behind your work, not just the output:

```bash
wai add research "findings"         # What you learned, trade-offs
wai add plan "approach"             # How you'll implement, why
wai add design "decisions"          # Architecture choices, rationale
wai add research --file notes.md    # Import longer content
```

Use `--project <name>` if multiple projects exist. Otherwise wai picks the first one.

Phases are a guide, not a gate. Use `wai phase show` / `wai phase next`.

## Ending a Session

Before saying "done", run this checklist:

```
[ ] wai handoff create <project>   # capture context for next session
[ ] wai reflect                    # update CLAUDE.md with project patterns (every ~5 sessions)
[ ] git add <files> && git commit  # commit code + handoff
```

### Autonomous Loop

One task per session. The resume loop:

1. `wai prime` — orient (shows ⚡ RESUMING if mid-task)
2. Work on the single task
3. `wai close` — capture state (run this before every `/clear`)
4. `git add <files> && git commit`
5. `/clear` — fresh context

→ Next session: `wai prime` shows RESUMING with exact next steps.

When context reaches ~40%: stop and tell the user — responses degrade past
this point. Recommend `wai close` then `/clear` to resume cleanly.
Do NOT skip `wai close` — it enables resume detection.

## Quick Reference

### wai
```bash
wai status                    # Project status and next steps
wai add research "notes"      # Add research artifact
wai add plan "plan"           # Add plan artifact
wai add design "design"       # Add design artifact
wai add skill <name>          # Scaffold a new agent skill
wai search "query"            # Search across artifacts
wai search --tag <tag>        # Filter by tag (repeatable)
wai search --latest           # Most recent match only
wai why "why use TOML?"       # Ask why (LLM-powered oracle)
wai why src/config.rs         # Explain a file's history
wai reflect                   # Synthesize project patterns into CLAUDE.md
wai close                     # Session handoff + pending-resume signal
wai phase show                # Current phase
wai doctor                    # Workspace health
wai pipeline list             # List pipelines
wai pipeline start <n> --topic=<t>  # Start a run; set WAI_PIPELINE_RUN=<id>
wai pipeline next             # Advance to next step
```

## Structure

The `.wai/` directory organizes artifacts using the PARA method:
- **projects/** — active work with phase tracking and dated artifacts
- **areas/** — ongoing responsibilities (no end date)
- **resources/** — reference material, agent configs, templates
- **archives/** — completed or inactive items

Do not edit `.wai/config.toml` directly. Use `wai` commands instead.

Keep this managed block so `wai init` can refresh the instructions.

<!-- WAI:END -->

<!-- WAI:REFLECT:REF:START -->
## Accumulated Project Patterns

Project-specific conventions, gotchas, and architecture notes live in
`.wai/resources/reflections/`. Run `wai search "<topic>"` to retrieve relevant
context before starting research or creating tickets.

> **Before research or ticket creation**: always run `wai search "<topic>"` to
> check for known patterns. Do not rediscover what is already documented.
<!-- WAI:REFLECT:REF:END -->


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
