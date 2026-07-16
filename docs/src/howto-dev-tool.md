# How-to: Use REPLy as a Global Dev Tool

!!! tip "Also see"
    If you use the REPLy CLI client (`replyc`), see
    [Install the `replyc` CLI Command](howto-cli-install.md) for automatic
    and manual installation instructions.

Like [Revise.jl](https://github.com/timholy/Revise.jl), **REPLy.jl** is most useful when it is always available in your development environment, regardless of which project you are currently working on.

By adding REPLy to your Julia `startup.jl` file, you can ensure that a REPLy server starts automatically whenever you launch an interactive Julia session.

## 1. Install REPLy in your Global Environment

First, add REPLy to your global (default) environment so it can be loaded from anywhere:

```julia
# Press ']' to enter Pkg mode
pkg> activate
pkg> add REPLy
```

## 2. Configure `startup.jl`

Open (or create) your Julia startup file, located at `~/.julia/config/startup.jl`. Add the following snippet:

```julia
atreplinit() do repl
    try
        @eval using REPLy
        # Start a server on the default port 5555
        REPLy.serve()
        # Alternatively, use a Unix socket for better local security:
        # REPLy.serve(socket_path=joinpath(homedir(), ".julia", "reply.sock"))
    catch e
        @warn "REPLy failed to start" exception=e
    end
end
```

### Why `atreplinit`?
Using `atreplinit` ensures the server only starts in **interactive** REPL sessions. This prevents the server from starting during package precompilation, running tests, or executing non-interactive scripts, where it might cause unexpected side effects or port conflicts.

### Why `@eval using REPLy`?
Using `@eval` inside the hook prevents Julia from trying to load REPLy immediately when the startup file is parsed. This keeps your non-interactive startup time fast.

!!! warning "Two REPLs at once will collide on the default port"
    The recipe above binds the fixed default port `5555`. Open a **second** interactive
    Julia session and its `REPLy.serve()` fails with an address-in-use error — and because
    the `try/catch` only `@warn`s, that second REPL comes up with **no server listening**
    while looking healthy. Your editor then gets "connection refused" with only a buried
    warning. Make the recipe idempotent instead:

    ```julia
    atreplinit() do repl
        try
            @eval using REPLy
            # Option A: per-process Unix socket — never collides, and access is
            # restricted to your user by file permissions.
            sock = joinpath(homedir(), ".julia", "reply-$(getpid()).sock")
            server = REPLy.serve(socket_path=sock)
            @info "REPLy listening" socket=REPLy.server_socket_path(server)

            # Option B (TCP): let the OS pick a free port with port=0, then print it
            # so your editor can discover which port this REPL got.
            # server = REPLy.serve(port=0)
            # @info "REPLy listening" port=REPLy.server_port(server)
        catch e
            @warn "REPLy failed to start" exception=e
        end
    end
    ```

    With `port=5555` fixed, only one REPL at a time can serve; a per-process socket or
    `port=0` lets every session bring up its own server.

## 3. Integration with Revise.jl

REPLy has built-in support for Revise.jl. If `Revise` is loaded in `Main`, REPLy calls `Revise.revise()` before an evaluation so your networked client sees the latest version of your code.

!!! note "Revise hook scope"
    The hook has two important boundaries:

    - **Named sessions only.** `Revise.revise()` runs before evals that target a named `session`. Session-less (ephemeral) evals skip the hook — there is no persistent module to refresh.
    - **Only what Revise tracks.** The hook re-applies changes to files Revise is watching — `dev`-ed package source and files loaded with `Revise.includet` — but **not** files loaded with plain `Base.include` / `include`. Load files you want auto-refreshed with `includet`.

    To turn the hook off entirely, pass `serve(...; limits=REPLy.ResourceLimits(revise_hook_enabled=false))`.

To use them together, update your `startup.jl`:

```julia
atreplinit() do repl
    try
        @eval using Revise
        @eval using REPLy
        REPLy.serve()
    catch e
        @warn "REPLy/Revise failed to start" exception=e
    end
end
```

## 4. Working with Project Environments

When you are working in a specific project (e.g., after `pkg> activate .`), the REPLy server running in your global environment will still be able to evaluate code using the project's dependencies, because it is running inside the same Julia process as your REPL.

## 5. Running as a Standalone Server

The `startup.jl` recipe above is the **foreground, interactive** pattern: you keep a live REPL in your terminal and a REPLy server runs alongside it. There are two distinct ways to run a server, and mixing them up is a common source of "connection refused" surprises.

### Foreground (interactive REPL)

Run an interactive session and let `startup.jl` (or a manual `REPLy.serve()`) start the server. Your terminal stays attached to the REPL:

```bash
julia --project=. -i startup.jl
```

The `-i` flag keeps Julia interactive, so the process stays alive as long as the REPL is open. This is the right mode when you want to type at the REPL *and* accept network clients.

### Background (headless server)

For a detached server with no human at the keyboard, write a small script that **starts the server and then blocks the main task forever**:

```julia
# server.jl
using REPLy

server = REPLy.serve(port=5555)
println("REPLy listening on $(REPLy.server_port(server))")

wait(Condition())   # block forever so the process does not exit
```

Run it in the background:

```bash
julia --project=. server.jl &
```

The `wait(Condition())` call is essential: `REPLy.serve` returns immediately (the listener runs on background tasks), so without a blocking call the script would reach the end and exit, tearing down the server.

!!! warning "Do not background the `-i` form"
    `julia --project=. -i startup.jl &` looks like it should work, but it exits in
    under a second with status `0` and no error. When a process is backgrounded, its
    stdin is detached; the interactive REPL immediately reads EOF and shuts Julia down,
    taking the server with it. You then see **Connection refused** with no log and a
    process that already exited cleanly.

    For a detached server always use the non-interactive `server.jl` + `wait(Condition())`
    pattern above — never `-i &`.

## 6. Security Note

Remember that REPLy carries **no authentication**. If you use the default TCP port `5555`, any process on your local machine can connect and execute code. For multi-user systems, we strongly recommend using a **Unix domain socket** as shown in the example above, which uses file-system permissions to restrict access to your user account.
