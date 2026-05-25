using Documenter
using SurrealDB

makedocs(;
    sitename = "SurrealDB.jl",
    modules = [SurrealDB],
    authors = "SurrealDB.jl contributors",
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Record IDs"     => "records.md",
            "Wire format"    => "wire.md",
            "Authentication" => "auth.md",
            "Live queries"   => "live.md",
            "Transactions"   => "transactions.md",
            "Reconnect"      => "reconnect.md",
            "Errors"         => "errors.md",
            "Integrations"   => "integrations.md",
            "Debugging"      => "debugging.md",
        ],
        "API Reference" => [
            "Connection & Auth" => "api/connection.md",
            "Query, Live, Transactions" => "api/query.md",
            "Types" => "api/types.md",
            "Errors" => "api/errors.md",
        ],
    ],
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://danvinci.github.io/surrealdb/",
        edit_link = "main",
        assets = String[],
    ),
    checkdocs = :exports,
    checkdocs_ignored_modules = [SurrealDB.SurrealCBOR],
    warnonly = true,
)

deploydocs(;
    repo = "github.com/danvinci/surrealdb",
    devbranch = "main",
    push_preview = false,
)
