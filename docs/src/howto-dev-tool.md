# How-to: Use REPLy as a Global Dev Tool

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

## 3. Integration with Revise.jl

REPLy has built-in support for Revise.jl. If `Revise` is loaded in your session, REPLy will automatically call `Revise.revise()` before every evaluation, ensuring your networked client always sees the latest version of your code.

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

## 5. Security Note

Remember that REPLy carries **no authentication**. If you use the default TCP port `5555`, any process on your local machine can connect and execute code. For multi-user systems, we strongly recommend using a **Unix domain socket** as shown in the example above, which uses file-system permissions to restrict access to your user account.
