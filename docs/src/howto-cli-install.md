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
   dependency snapshot at build time.
2. Writes a `replyc` launcher script to `<depot>/bin/replyc` (where
   `<depot>` is `DEPOT_PATH[1]`, typically `~/.julia`).
3. Pins the launcher to the scratch-space environment so it resolves REPLy
   deterministically, independent of changes to your global environment.

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
exec env JULIA_PROJECT="/path/to/scratch/env" julia --startup-file=no \
    -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- "$@"
```

It sets `JULIA_PROJECT` to the frozen scratch environment and overrides any
`JULIA_PROJECT` that may be set in your outer shell. This guarantees that
`replyc` always resolves the same REPLy version and dependencies it was built
with.

### Overwrite guard

If a file already exists at `<depot>/bin/replyc` and does **not** appear to
belong to REPLy (i.e., it lacks the UUID marker shown above), `Pkg.build`
will refuse to overwrite it and print a warning. Remove the conflicting file
manually and re-run `Pkg.build("REPLy")` to install the REPLy launcher.

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

The scratch-space environment may not be fully instantiated. Run:

```bash
julia --project="$(julia -e 'using Scratch; println(get_scratch!(REPLy, "env"))')" \
    -e 'using Pkg; Pkg.instantiate()'
```

This resolves and precompiles all dependencies in the scratch environment.

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
