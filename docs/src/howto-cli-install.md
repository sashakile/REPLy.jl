# How-to: Install the `replyc` CLI Command

`replyc` is a minimal TCP/JSON CLI client for REPLy. It sends `eval` and
`session` requests over a socket and prints the structured JSON response.

There are two ways to use `replyc` as a bare command:

- **Automatic** (recommended): `deps/build.jl` installs a `replyc` launcher
  into your Julia depot's `bin` directory.
- **Manual**: Symlink the project's `bin/replyc` into your `PATH` when you
  need a project-scoped, self-resolving version.

Both assume Julia + REPLy are already present on your system. `replyc` is
never distributed separately — it is a companion tool for REPLy users.

## Prerequisites

- Julia 1.10+
- REPLy.jl installed (via `Pkg.add` or `Pkg.develop`)
- Your Julia depot `bin` directory on `PATH` (see [PATH Setup](#path-setup))

## Automatic Install (via `Pkg.build`)

When you add or develop REPLy, `deps/build.jl` runs automatically via
`Pkg.build`. It:

1. Creates a private scratch-space environment that freezes REPLy's
   dependency snapshot at build time (for reference and troubleshooting).
2. Writes a `replyc` launcher script to `<depot>/bin/replyc` (where
   `<depot>` is `DEPOT_PATH[1]`, typically `~/.julia`), pinned to REPLy's
   project directory via `--project`.

To install:

```julia
julia -e 'using Pkg; Pkg.add(url="https://github.com/sashakile/REPLy.jl")'
```

Or if you are developing locally:

```julia
julia -e 'using Pkg; Pkg.develop(path="/path/to/REPLy.jl")'
```

After that, ensure `<depot>/bin` is on your `PATH` (see below) and verify:

```bash
replyc --help
```

### What the launcher does

The generated `replyc` launcher is a small bash script:

```bash
#!/usr/bin/env bash
# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51
exec julia --startup-file=no --project="/path/to/reply/project" \
    -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- "$@"
```

It uses `--project` to point to REPLy's project directory at build time,
which means it always resolves the same REPLy version and dependencies.
Because `--project` overrides any `JULIA_PROJECT` set in your outer shell,
the launcher avoids surprises from accidental project-switching.

!!! note "Path stays at build time"
    The launcher caches the project path as it was when you last ran
    `Pkg.build`. If you later garbage-collect or upgrade Julia, re-run
    `Pkg.build("REPLy")` to regenerate the launcher.

### Overwrite guard

If a file already exists at `<depot>/bin/replyc` and does **not** appear to
belong to REPLy (i.e., it lacks the UUID marker shown above), `Pkg.build`
will refuse to overwrite it and print a warning. Remove the conflicting file
manually and re-run `Pkg.build("REPLy")` to install the REPLy launcher.

## Using `replyc`

`replyc` talks to an already-running REPLy server (start one with
`REPLy.serve(port=5555)` — see [Quick Start](index.md#Quick-Start)). Run `replyc --help`
for the full usage:

```text
replyc — minimal REPLy client

Usage:
  replyc eval    [--host H] [--port N] [--session NAME] 'CODE'
  replyc session new [--host H] [--port N] [NAME]
  replyc session ls  [--host H] [--port N]
  replyc session rm  [--host H] [--port N] NAME

Defaults: --host 127.0.0.1  --port 5555
```

### First eval

Evaluate an expression against the default server and read the result on stdout:

```bash
replyc eval '1 + 1'
```

```text
2
```

Standard output from the code is streamed too; the final value prints last:

```bash
replyc eval 'println("hi"); 3 * 7'
```

```text
hi
21
```

A runtime error is printed to stderr and `replyc` exits non-zero:

```bash
replyc eval 'missing_name + 1'; echo "exit=$?"
```

```text
UndefVarError: `missing_name` not defined
exit=1
```

### Persistent state with sessions

By default each `eval` runs in a fresh ephemeral session. To keep variables between calls,
create a named session and pass `--session`:

```bash
replyc session new main          # prints the new session UUID
replyc eval --session main 'x = 42'
replyc eval --session main 'x + 10'
```

```text
52
```

List and remove sessions:

```bash
replyc session ls                # prints "<uuid>\t<name>" per session
replyc session rm main           # close by name or UUID
```

Use `--host`/`--port` to reach a non-default server (for Unix sockets, see
[Unix Sockets](howto-unix-sockets.md)). This maps directly onto the wire protocol: `eval`
sends an `eval` op, `--session` sets the `"session"` key, and `session new/ls/rm` send
`new-session`/`ls-sessions`/`close`. See the [Protocol Reference](reference-protocol.md) for
the underlying messages.

## Manual Install (Project-Scoped)

If you need `replyc` to resolve a specific project's REPLy version (e.g., a
repo that pins an older REPLy commit), use the existing `bin/replyc` shebang
wrapper instead of the global launcher:

```bash
ln -s "$(julia -e 'using REPLy; print(pkgdir(REPLy))')/bin/replyc" ~/.local/bin/replyc
```

This version resolves REPLy from whichever Julia environment is **active at
invocation time**, not from a frozen scratch space. Use this when different
projects need different REPLy versions.

## PATH Setup

For the launcher to work as a bare command, Julia's depot `bin` directory
must be on your `PATH`. Add one of the following to your shell configuration
(`~/.bashrc`, `~/.zshrc`, etc.):

```bash
# Default depot — works for most setups
export PATH="$HOME/.julia/bin:$PATH"

# Custom depot — respects JULIA_DEPOT_PATH if set
export PATH="$(julia -e 'print(joinpath(DEPOT_PATH[1], "bin"))'):$PATH"
```

## Troubleshooting

### `replyc: command not found`

Ensure `<depot>/bin` is on `PATH` (see [PATH Setup](#path-setup)). Run
`Pkg.build("REPLy")` to confirm the launcher was installed:

```bash
julia --project=. -e 'using Pkg; Pkg.build("REPLy")'
```

### `Refusing to overwrite` warning

Another file named `replyc` exists at `<depot>/bin/replyc`. If it is safe to
replace, remove it and re-run `Pkg.build`:

```bash
rm "$(julia -e 'println(joinpath(DEPOT_PATH[1], "bin", "replyc"))')"
julia -e 'using Pkg; Pkg.build("REPLy")'
```

### `ArgumentError: Package REPLy not found`

The launcher is pinned to REPLy's project directory at build time. If REPLy
was removed or moved since then, the path is stale. Re-run `Pkg.build` to
regenerate the launcher:

```bash
julia -e 'using Pkg; Pkg.build("REPLy")
```

If you upgraded Julia or ran `Pkg.gc()` since installing REPLy, the package
path may have changed. A fresh build always captures the current path.

## Uninstall

Julia's package lifecycle does not provide an uninstall hook. When you remove
REPLy, the `replyc` launcher at `<depot>/bin/replyc` becomes orphaned. To
clean it up manually:

```bash
rm "$(julia -e 'println(joinpath(DEPOT_PATH[1], "bin", "replyc"))')"
```

## Related

- [Use REPLy as a Global Dev Tool](howto-dev-tool.md) — Setting up the REPLy
  server for interactive development.
- [Unix Sockets](howto-unix-sockets.md) — Connecting `replyc` to a Unix socket
  server.
