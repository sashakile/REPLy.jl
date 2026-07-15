---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

# REPLy.jl — `replyc` Distribution Research (2026-07-15)

**What's REPLy.jl?** A TCP/JSON-over-socket interactive Julia REPL server
(`github.com/sashakile/reply.jl`). `replyc` is its bundled minimal CLI client
(`REPLy.replyc`, plus a `bin/replyc` shebang wrapper) — send an `eval` or
`session` request over the socket and print the structured JSON response.

**Purpose of this document:** the maintainer asked whether `replyc` could be
compiled to a standalone binary via `juliac` (Julia 1.12's built-in
AOT-compiler driver), and separately, how to make `replyc` trivially
installable given that REPLy is always used inside a Julia environment (never
handed to a non-Julia user). This document records what was actually tried,
what worked, what didn't, and why the two follow-on ideas (`Pkg.build`
launcher install, and Comonicon.jl's approach to the same problem) land where
they do. Everything below was verified against a live clone of `main`
(`sashakile/reply.jl`, commit `ed33ff8`, Julia 1.12.6, macOS/arm64) — no
speculation, only tested claims are stated as fact.

---

## 1. Can `replyc` be compiled with `juliac`?

Julia 1.12 ships a built-in compiler driver at
`share/julia/juliac/juliac.jl`. Two modes were tested.

### 1a. Plain `--output-exe` (no `--trim`) — works, zero source changes

Added a 6-line entry file:

```julia
using REPLy
function main(args::Vector{String})::Cint
    return REPLy.replyc(args)
end
@main
```

Built successfully (`julia --project=. juliac.jl --experimental --output-exe
replyc bin/replyc_juliac.jl`, ~74s). Verified end-to-end against a live
`REPLy.serve()` instance — `eval` and `session new` both round-tripped
correctly through the compiled binary.

**Results:**
- Binary size: ~252 MB (embeds the entire stdlib sysimage, untrimmed)
- Not fully static: still links `@rpath/libjulia.1.12.dylib` /
  `libjulia-internal.dylib` — needs `--relative-rpath` to bundle those
  alongside the binary for redistribution
- Warm startup: ~86 ms (vs. ~620–645 ms for `julia -e 'using REPLy; ...'`)
- Cold (page-cache-miss) startup: ~1.9 s, once, after each fresh build/reboot

### 1b. `--trim=safe` / `--trim=unsafe-warn` — does not work without a rewrite

`--trim` performs whole-program reachability verification and refuses to
compile anything statically unresolvable. Result: **149 verifier errors**,
all rooted in `replyc.jl`'s wire-protocol handling being built on
`Dict{String,Any}` plus JSON3's `Any`-typed dispatch (`msg["value"]`,
`request["id"]`, etc.) — none of that is staticaly resolvable.

`--trim=unsafe-warn` still forced a binary out despite the errors (1.95 MB!)
but it **crashes at runtime**:

```
Core.MissingCodeError(mi=print(Base.PipeEndpoint, Core.String) from print(Core.IO, Any))
```

Making `--trim` viable would require replacing the `Dict{String,Any}`
request/response plumbing with concrete typed structs (e.g.
`StructTypes`-backed types) throughout `replyc.jl` — a real refactor, not a
build-script flag.

### 1c. Reframing: does the exe even solve a real problem?

The README shows `replyc` is *always* invoked as
`julia -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- ...` — i.e. the tool
assumes Julia + REPLy are already present. Nobody hands `replyc` to a
non-Julia user. That kills the main reason to want a standalone exe.

What the exe *actually* buys, given that framing, is warm-startup latency —
and a **custom sysimage** buys the identical number with far less risk:

```
julia --project=. juliac.jl --experimental --output-sysimage replyc.dylib entry.jl
julia --project=. --sysimage=replyc.dylib -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- ...
```

| | cold | warm |
|---|---|---|
| `julia -e 'using REPLy; ...'` (today) | ~640 ms | ~620–645 ms, every call |
| `juliac --output-exe` | ~1.9 s | ~86 ms |
| `juliac --output-sysimage` + `--sysimage=` | ~1.9 s | ~93 ms |

The sysimage route needs **no `@main`/entrypoint restructuring**, **no
`--trim` risk** (it doesn't do reachability verification), and preserves the
exact current invocation shape. Either artifact is ~250 MB, tied to the exact
Julia version/arch it was built with, and not something to commit to git.

**Verdict on this line of investigation: not worth pursuing right now.**
`replyc` is a short-lived, I/O-bound network client invoked by a human or an
agent loop, not a tight loop calling it thousands of times per second — the
~550 ms saved per call doesn't offset the artifact-management overhead
(rebuild on every REPLy/Julia version bump, ~250 MB per machine, no portable
distribution benefit since Julia is already assumed present). Revisit only if
concrete evidence emerges of `replyc` being called in a genuinely
latency-sensitive hot loop.

---

## 2. The actual gap: `replyc` has no installable *command*

Reframing the problem correctly: since Julia + REPLy are always present,
"distribution" isn't about portability — it's about not making users
hand-type `julia -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- ...` every
time.

Two things were found broken/aspirational in the current docs:

1. **`Pkg.add("REPLy")` doesn't work.** REPLy is not in Julia's General
   registry (checked `~/.julia/registries/General` — no match for its UUID).
   Today it only installs via `Pkg.add(url="https://github.com/sashakile/REPLy.jl")`
   or a git-pinned `Manifest.toml` entry (`repo-url`/`repo-rev="main"`, as
   this workspace's own `Manifest.toml` already does). The maintainer
   confirmed this is *deliberate* — registration is being held back until the
   tool is stable, not blocked by any packaging defect. **Out of scope for
   this document**: nothing about CLI ergonomics should push early
   registration.

2. **`bin/replyc` already works as a bare command** — it just isn't
   documented as such. It's already executable in git (`100755`,
   `#!/usr/bin/env julia` shebang). Verified live: once REPLy is added to a
   user's **global** environment (the same convention `docs/howto-dev-tool.md`
   already documents for the server half of this tool) and `bin/` is on
   `PATH`, `replyc --help` runs correctly in ~650 ms, no shim, no build step,
   no new dependency.

First recommendation (rule-of-5 pass, converged early): add a short
"Installing the `replyc` command" doc section, no code changes:

```bash
julia -e 'using Pkg; Pkg.activate(); Pkg.add(url="https://github.com/sashakile/REPLy.jl")'
ln -s "$(julia -e 'using REPLy; print(pkgdir(REPLy))')/bin/replyc" ~/.local/bin/replyc
```

The maintainer pushed back on this — the goal is zero manual steps, not a
documented one-liner. That produced the `deps/build.jl` design below.

---

## 3. `deps/build.jl`: auto-install a `replyc` launcher

Julia's `Pkg.build` runs `deps/build.jl` automatically on `Pkg.add`/`Pkg.build`
for any package that has one — no explicit opt-in needed by the user. Drafted
and tested:

```julia
bin_dir = joinpath(DEPOT_PATH[1], "bin")
launcher_path = joinpath(bin_dir, "replyc")

launcher_src = """
#!/usr/bin/env bash
exec julia --startup-file=no -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- "\$@"
"""

mkpath(bin_dir)
write(launcher_path, launcher_src)
chmod(launcher_path, 0o755)
```

Verified live: `Pkg.develop(path=...)` on a temp env triggers this
automatically; `replyc --help` then works from a plain `PATH` lookup, no
manual step beyond adding `~/.julia/bin` to `PATH` once (a pre-existing Julia
ecosystem convention — see §4).

### 3a. Does this create conflicts across repos?

Tested directly: two isolated depots (`JULIA_DEPOT_PATH` pointed at
`/tmp/depotA` and `/tmp/depotB`) each ran `Pkg.build("REPLy")` against
different local checkouts. The two resulting `bin/replyc` launcher scripts
were **byte-identical** (`diff` confirmed). This is because the launcher
script is fully generic — no path, no version, no git rev baked in — it just
runs `julia -e 'using REPLy; ...'` and resolves REPLy from whatever
environment is active *at invocation time* (normally the user's global env),
not the environment that happened to trigger the build.

Two distinct consequences follow, and they are **not the same problem**:

- **Version drift across repos, not really a "conflict" but a scoping
  limitation.** `~/.julia/bin/replyc` can only ever point at *one* REPLy
  install at a time (whatever the global env resolves). If repo A needs a
  pinned old commit and repo B needs unreleased `main` (exactly the situation
  in this workspace: `julians/REPLy.jl` vs. `sandbox/reply/` pin different
  revs independently), the global launcher cannot serve both. This mirrors
  how the docs already position REPLy — "a global dev tool, like Revise" —
  so this is a correct, inherent constraint, not a bug: any repo needing an
  incompatible version should keep using the already-working project-scoped
  form, `julia --project=path/to/repo -e '...'`.

- **Namespace collision with unrelated tools, a real unmitigated gap.**
  `deps/build.jl` unconditionally overwrites whatever file is at
  `~/.julia/bin/replyc`, with no ownership check. If any other, unrelated
  package also ships a command literally named `replyc`, whichever package
  builds last wins silently. No warning, no error.

---

## 4. How does Comonicon.jl handle the same problem?

Comonicon.jl is the Julia ecosystem's standard tool for turning a package
function into an installable CLI. Read `src/builder/install.jl` and
`src/builder/sysimg.jl` directly from its `main` branch to answer precisely
rather than by inference.

**`install_entryfile` (`install.jl:31-43`) does exactly what `deps/build.jl`
does** — writes a script to `<depot>/bin/<name>`, `chmod 0o777`, **no
ownership check, no collision detection**. Two unrelated packages naming
their command the same thing will clobber each other on install, silently,
identically to the gap found in §3a. **Comonicon does not solve the
namespace-collision problem either** — this appears to be an open,
unaddressed gap across the whole `~/.julia/bin` convention, not something
fixable at the single-package level.

**What Comonicon *does* solve — version drift — via a private, frozen
per-package environment:**

1. `get_scratch!(m, "env")` (`Scratch.jl`) gives each package **UUID** its own
   private directory under `~/.julia/scratchspaces/<uuid>/env` — inherently
   namespaced per package, never collides across *different* packages.
2. `create_command_env` (`sysimg.jl:40-65`) copies that package's own
   `Project.toml` deps/compat (plus test deps) into a synthetic project inside
   the scratch dir and instantiates it — a frozen dependency snapshot taken
   **at install time**, not resolved dynamically at every invocation.
3. The generated launcher (`_entryfile_script_bash`, `install.jl`) hardcodes
   `JULIA_PROJECT=<scratch_env_dir>` into the script itself via a bash/Julia
   polyglot trick: a `#=...=#` block is parsed by bash as a comment
   containing a multi-line command that re-execs
   `julia --project=<scratch_env> ... -- "$0" "$@"`; the same file, read by
   Julia with that `--project`, is valid Julia below the block
   (`using $m; exit($m.command_main())`).

So the practical difference from `deps/build.jl` as drafted: Comonicon's
launcher is **pinned to the exact dependency snapshot that existed at the
most recent `install()`/build**, not to "whatever `using REPLy` resolves to
in the global env right now." This removes one specific failure mode —
silent behavior drift if the global env changes after the launcher was
written — without requiring Comonicon itself as a dependency (the trick is
~25 lines using `Scratch.jl`, already a small, ubiquitous package).

**What Comonicon still cannot do:** run two different pinned versions of the
*same* command name (`replyc`) simultaneously for two different repos.
`~/.julia/bin/<name>` is a single global slot in both designs; Comonicon only
makes what's *in* that slot self-consistent, not the slot itself
multi-tenant. For genuinely incompatible per-repo versions, the answer in
both worlds is identical: skip the global launcher, invoke project-scoped.

---

## 5. Summary table

| Question | Finding |
|---|---|
| Can `replyc` compile via `juliac --output-exe`? | Yes, works today, zero code changes, ~252 MB, ~86 ms warm startup |
| Can it compile with `--trim`? | No — 149 verifier errors from `Dict{String,Any}`/JSON3 dynamic dispatch; the `unsafe-warn` binary crashes at runtime |
| Is compiling it worth doing? | No (current recommendation) — `replyc` isn't latency-sensitive enough to justify a ~250 MB per-machine artifact and rebuild-on-version-bump discipline |
| Does `Pkg.add("REPLy")` work today? | No — not registered in General; deliberate, pending tool stability; out of scope to fix here |
| Does `bin/replyc` already work as a bare command? | Yes, verified live — needs global-env install + `PATH`, no code changes |
| Does `deps/build.jl` avoid manual install steps? | Yes, verified live via `Pkg.build` auto-run |
| Does `deps/build.jl` avoid conflicts across repos with different REPLy versions? | No — and it structurally cannot; global launcher = single active version, same limitation Comonicon has |
| Does `deps/build.jl` avoid namespace collisions with unrelated tools named `replyc`? | No — unconditional overwrite, matches Comonicon's own `install_entryfile` behavior exactly |
| Does Comonicon solve either conflict class better? | Only version drift, via per-package-UUID scratch-space environments frozen at build time — not namespace collision |

## 6. Open recommendation (not yet decided)

Two independent, small upgrades to `deps/build.jl` were identified but not
applied, pending a decision on whether they're worth the complexity for a
dev-convenience tool:

1. **Pin via a scratch-space environment** (Comonicon's trick, minus the
   dependency) instead of dynamically resolving `using REPLy` from the global
   env at invocation time — removes the "global env changed underneath you"
   drift failure mode.
2. **Overwrite guard** — refuse to clobber a file at `~/.julia/bin/replyc`
   that doesn't contain REPLy's own marker comment, and warn instead of
   silently overwriting. Cheap, and closes (for REPLy's own launcher, not the
   general ecosystem problem) the one collision case that's actually
   preventable: re-running `Pkg.build` shouldn't quietly clobber a
   hand-installed or third-party file at the same path.

Both remain YAGNI candidates until there's concrete evidence of the failure
mode occurring in practice.
