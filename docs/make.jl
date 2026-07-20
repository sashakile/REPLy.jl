using Documenter, REPLy
using Documenter: Remotes

makedocs(
    sitename = "REPLy.jl",
    modules  = [REPLy],
    repo     = Remotes.GitHub("sashakile", "REPLy.jl"),
    format   = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
    ),
    pages = [
        "Home" => "index.md",
        "Guides" => [
            "How-to: REPLy as a Global Dev Tool" => "howto-dev-tool.md",
            "How-to: Manage Sessions" => "howto-sessions.md",
            "How-to: MCP Adapter" => "howto-mcp-adapter.md",
            "How-to: Unix Sockets" => "howto-unix-sockets.md",
            "How-to: Install the `replyc` CLI" => "howto-cli-install.md",
            "How-to: Use the `replyc` CLI" => "howto-replyc.md",
            "How-to: Custom Middleware" => "howto-custom-middleware.md",
            "Tutorial: Custom Client" => "tutorial-custom-client.md",
        ],
        "Reference" => [
            "Protocol Reference" => "reference-protocol.md",
        ],
        "Status" => "status.md",
        "Methodology" => "methodology.md",
        "API"  => "api.md",
    ],
    checkdocs = :exports,
    warnonly  = false,
)
