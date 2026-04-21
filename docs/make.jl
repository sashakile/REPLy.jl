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
            "How-to: Manage Sessions" => "howto-sessions.md",
            "How-to: Unix Sockets" => "howto-unix-sockets.md",
            "Tutorial: Custom Client" => "tutorial-custom-client.md",
        ],
        "Status" => "status.md",
        "API"  => "api.md",
    ],
    checkdocs = :exports,
    warnonly  = false,
)
