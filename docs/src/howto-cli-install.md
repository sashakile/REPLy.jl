# How-to: Install the `replyc` CLI Command

> **TL;DR** — Run `julia -e 'using Pkg; Pkg.add(url="...REPLy.jl")'` then add
> `<depot>/bin` to your `PATH`. The build script installs a `replyc` launcher
> automatically. See [Automatic Install](#automatic-install-via-pkgbuild) below.

`replyc` is a minimal TCP/JSON CLI client for REPLy. It sends `eval` and
`session` requests over a socket and prints the structured JSON response.

On Unix-like systems, there are two ways to use `replyc` as a bare command:

- **Automatic** (recommended): `deps/build.jl` installs a `replyc` launcher
  into your Julia depot's `bin` directory.
- **Manual**: Symlink the project's `bin/replyc` into your `PATH` and select
  the desired Julia environment when invoking it.

Both assume Julia + REPLy are already present on your system. `replyc` is
never distributed separately — it is a companion tool for REPLy users.

## Prerequisites

- Julia 1.10+
- REPLy.jl installed (via `Pkg.add` or `Pkg.develop`)
- Your Julia depot `bin` directory on `PATH` (see [PATH Setup](#path-setup))

## Automatic Install (via `Pkg.build`)

When you add or develop REPLy, `deps/build.jl` runs automatically via
`Pkg.build`. It:

1. Creates and instantiates a private scratch-space environment containing
   REPLy and its dependency closure.
2. Writes a `replyc` launcher script to `<depot>/bin/replyc` (where
   `<depot>` is `DEPOT_PATH[1]`, typically `~/.julia`), pinned to that scratch
   environment via `--project`.

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
exec julia --startup-file=no --project="/path/to/reply/scratch/environment" \
    -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- "$@"
```

It uses `--project` to point to the scratch environment created at build time,
which means it resolves the REPLy version and dependency snapshot installed there.
Because `--project` overrides any `JULIA_PROJECT` set in your outer shell,
the launcher avoids surprises from accidental project-switching.

!!! note "Rebuild after changing REPLy"
    The launcher continues to use the scratch environment created by the most
    recent build. Re-run `Pkg.build("REPLy")` after upgrading, moving, or
    removing the REPLy installation used to create it.

### Overwrite guard

If a file already exists at `<depot>/bin/replyc` and does **not** appear to
belong to REPLy (i.e., it lacks the UUID marker shown above), `Pkg.build`
will refuse to overwrite it and print a warning:

```text
┌ Warning: Refusing to overwrite existing replyc at /home/user/.julia/bin/replyc
│ (file does not appear to belong to REPLy)
└ Remove the file manually or run with FORCE=1
```

Remove the conflicting file and re-run `Pkg.build("REPLy")` to install
the REPLy launcher:

```bash
rm "$(julia -e 'println(joinpath(DEPOT_PATH[1], "bin", "replyc"))')"
julia -e 'using Pkg; Pkg.build("REPLy")'
```

## Using `replyc`

`replyc` talks to an already-running REPLy server (start one with
`REPLy.serve(port=5555)` — see [Quick Start](index.md#Quick-Start)). Once
the launcher is on your `PATH`, run `replyc --help`:

```text
replyc — minimal REPLy client

Usage:
  replyc eval    [--host H] [--port N] [--session NAME] 'CODE'
  replyc session new [--host H] [--port N] [NAME]
  replyc session ls  [--host H] [--port N]
  replyc session rm  [--host H] [--port N] NAME

Defaults: --host 127.0.0.1  --port 5555
```

See [How-to: Use the `replyc` CLI](howto-replyc.md) for the full usage guide,
including eval examples, session workflows, exit codes, and shell composition.

This maps directly onto the wire protocol: `eval` sends an `eval` op,
`--session` sets the `"session"` key, and `session new/ls/rm` send
`new-session`/`ls-sessions`/`close`. See the [Protocol Reference](reference-protocol.md)
for the underlying messages.

## Manual Install on Unix

To use the checkout convenience wrapper instead of the global launcher, symlink
`bin/replyc` into your path:

```bash
# Requires REPLy to be loadable first (run Pkg.add or Pkg.develop first)
ln -s "$(julia -e 'using REPLy; print(pkgdir(REPLy))')/bin/replyc" ~/.local/bin/replyc
```

!!! warning "This command needs REPLy installed first"
    `using REPLy` inside the substitution must succeed. If you haven't installed
    REPLy yet, the command produces a "Package REPLy not found" error. Install
    REPLy first (see [Automatic Install](#automatic-install-via-pkgbuild) above) or
    use [Direct Invocation](#direct-invocation-including-windows) instead.

This wrapper uses Julia's normal environment selection. Set `JULIA_PROJECT` when a
specific project pins REPLy, for example:

```bash
JULIA_PROJECT=/path/to/project replyc eval '1 + 1'
```

## Direct Invocation (Including Windows)

The generated and symlinked launchers rely on Unix shebang/Bash behavior. On
Windows, or when you want to select an environment explicitly without installing a
launcher, invoke the client through Julia:

```bash
julia --project=/path/to/environment -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- eval '1 + 1'
```

## PATH Setup

For the launcher to work as a bare command, Julia's depot `bin` directory
must be on your `PATH`. Add the following to your shell configuration
(`~/.bashrc`, `~/.zshrc`, etc.). The second, portable form is preferred:

```bash
# Preferred — respects JULIA_DEPOT_PATH if set
export PATH="$(julia -e 'print(joinpath(DEPOT_PATH[1], "bin"))'):$PATH"

# Common-default fallback (works when JULIA_DEPOT_PATH is unset)
export PATH="$HOME/.julia/bin:$PATH"
```

The portable form uses `DEPOT_PATH[1]` which matches Julia's actual depot
resolution. The `~/.julia/bin` shortcut works for most default installations
but breaks under custom `JULIA_DEPOT_PATH`.

## Troubleshooting

### `replyc: command not found`

Ensure `<depot>/bin` is on `PATH` (see [PATH Setup](#path-setup)). Run
`Pkg.build("REPLy")` to confirm the launcher was installed:

```bash
julia --project=. -e 'using Pkg; Pkg.build("REPLy")'
```

### `Refusing to overwrite` warning

Another file named `replyc` exists at `<depot>/bin/replyc`. See the
[Overwrite guard](#overwrite-guard) section above for the warning text and
resolution steps.

### `ArgumentError: Package REPLy not found`

The launcher's scratch environment can become stale if its development path to
REPLy was removed or moved. Re-run `Pkg.build` from an environment where REPLy
is installed to recreate the scratch environment and launcher:

```bash
julia -e 'using Pkg; Pkg.build("REPLy")'
```

If you upgraded Julia or ran `Pkg.gc()` since installing REPLy, a fresh build
recreates the environment from the current package path.

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
