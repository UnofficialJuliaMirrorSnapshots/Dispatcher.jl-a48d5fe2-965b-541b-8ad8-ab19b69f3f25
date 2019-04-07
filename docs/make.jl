using Documenter, Dispatcher

makedocs(
    # options
    modules = [Dispatcher],
    format = :html,
    pages = [
        "Home" => "index.md",
        "Manual" => "pages/manual.md",
        "API" => "pages/api.md",
    ],
    sitename = "Dispatcher.jl",
    authors = "Invenia Technical Computing",
    assets = ["assets/invenia.css"],
)

deploydocs(
    repo = "github.com/invenia/Dispatcher.jl.git",
    julia = "0.6",
    target = "build",
    deps = nothing,
    make = nothing,
)
