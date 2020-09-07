using Documenter
push!(LOAD_PATH, joinpath(@__DIR__, "../src/"))
using Q

makedocs(
    modules   = [Q, Q._k],
    sitename  = "Q.jl - Julia for kdb+",
    linkcheck = true,
    pages = [
        "Home" => "index.md",
        "Manual" => [
            "manual/common-api.md",
            "manual/client.md",
            "manual/server.md",
            "manual/low-level.md",
        ]
    ],
)

deploydocs(
    deps   = Deps.pip("mkdocs", "python-markdown-math"),
    repo = "github.com/enlnt/Q.jl.git",
    julia  = "1.4",
    osname = "linux",
)
