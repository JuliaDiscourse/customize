"""
    DiscourseAdmin

Keep this repository and the live configuration of a Discourse instance in
sync in both directions, by convention: the repository's `admin/` tree
mirrors the admin API routes of the same paths — `admin/customize/site_texts/`
holds one file per entry on the `/admin/customize/site_texts` route — with
each filename being the configuration key (plus an optional `.txt`/`.md`
display extension) and its contents the configured value. Only paths under
`admin/` are synced, and dotfiles (like a `.gitkeep` holding an empty
directory in git) are ignored. Supporting another endpoint is a matter of
`mkdir -p`.

The two CLI entry points used by the GitHub workflows are
[`main_pull`](@ref) (mirror the live state into the repository) and
[`main_push`](@ref) (apply committed changes to the live site).
"""
module DiscourseAdmin

using HTTP
using JSON

export Client

const DEFAULT_BASE_URL = "https://discourse.julialang.org"
const LOCALE = "en"

# ---------------------------------------------------------------------------
# The Discourse admin API

"""
    Client(; base_url=DEFAULT_BASE_URL, api_key, api_user)

A connection to the admin API of a Discourse instance.
"""
Base.@kwdef struct Client
    base_url::String = DEFAULT_BASE_URL
    api_key::String
    api_user::String
end

has_credentials() = !isempty(get(ENV, "API_KEY", "")) && !isempty(get(ENV, "API_USER", ""))

"""
    client_from_env() -> Client

Construct a [`Client`](@ref) from the `API_KEY` and `API_USER` environment
variables, with `DISCOURSE_URL` optionally overriding the instance URL.
"""
function client_from_env()
    has_credentials() || error("API_KEY and API_USER must be set")
    return Client(base_url = get(ENV, "DISCOURSE_URL", DEFAULT_BASE_URL),
                  api_key = ENV["API_KEY"], api_user = ENV["API_USER"])
end

auth_headers(c::Client) = ["Api-Key" => c.api_key, "Api-Username" => c.api_user]

# Discourse is Rails: a route's JSON objects and form fields use the
# singular of its last segment (admin/customize/site_texts → site_text)
singular(dir) = chopsuffix(basename(dir), "s")

endpoint(c::Client, dir, key = nothing) =
    "$(c.base_url)/$dir$(isnothing(key) ? "" : "/$(HTTP.escapeuri(key))")"

"""
    configured_keys(c::Client, dir) -> Vector{String}

The keys of every entry currently configured on the `dir` endpoint,
following `extras.has_more` pagination through the `page` parameter.
"""
function configured_keys(c::Client, dir)
    keys = String[]
    page = 0
    while true
        resp = HTTP.get("$(endpoint(c, dir)).json";
                        query = ["overridden" => "true", "locale" => LOCALE,
                                 "page" => string(page)],
                        headers = auth_headers(c))
        data = JSON.parse(String(resp.body))
        append!(keys, String[t["id"] for t in data[basename(dir)]])
        get(get(data, "extras", Dict()), "has_more", false) || return keys
        page += 1
    end
end

"""
    get_value(c::Client, dir, key) -> String

The currently-configured value of `key` on the `dir` endpoint.
"""
function get_value(c::Client, dir, key)
    resp = HTTP.get("$(endpoint(c, dir, key)).json";
                    query = ["locale" => LOCALE], headers = auth_headers(c))
    return JSON.parse(String(resp.body))[singular(dir)]["value"]::String
end

"""
    set_value!(c::Client, dir, key, value)

Create or update the configuration of `key` on the `dir` endpoint.
"""
function set_value!(c::Client, dir, key, value)
    HTTP.put(endpoint(c, dir, key);
             headers = [auth_headers(c);
                        "Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8"],
             body = HTTP.escapeuri(["$(singular(dir))[value]" => value,
                                    "$(singular(dir))[locale]" => LOCALE]))
    return nothing
end

"""
    reset_value!(c::Client, dir, key)

Remove the configuration of `key`, reverting it to the Discourse default.
"""
function reset_value!(c::Client, dir, key)
    HTTP.delete(endpoint(c, dir, key);
                query = ["locale" => LOCALE], headers = auth_headers(c))
    return nothing
end

# ---------------------------------------------------------------------------
# Repository conventions

"The repository directories mirroring API routes: every leaf directory under admin/."
function config_dirs(root = "admin")
    isdir(root) || return String[]
    dirs = String[]
    for (path, subdirs, _) in walkdir(root)
        isempty(subdirs) && push!(dirs, path)
    end
    return sort!(dirs)
end

# Configuration keys themselves contain dots (e.g. guidelines_topic.body),
# so only the known display extensions (.txt, .md — kept so files render
# nicely on GitHub) are stripped from a filename to form the key.
key_for_file(file) = replace(basename(file), r"\.(txt|md)$" => "")

# Map each configured key to its on-disk file (ignoring dotfiles), so an
# existing file's display extension is preserved when its value is updated.
function existing_files_by_key(dir)
    isdir(dir) || return Dict{String,String}()
    return Dict{String,String}(key_for_file(f) => joinpath(dir, f)
                               for f in readdir(dir) if !startswith(f, "."))
end

# ---------------------------------------------------------------------------
# Pull: mirror the live state into the repository

"""
    pull!(c::Client, dirs=config_dirs())

Mirror the live configuration of each endpoint into its directory, adding,
updating, and removing files so it exactly reflects the live state.
"""
function pull!(c::Client, dirs = config_dirs())
    for dir in dirs
        keys = configured_keys(c, dir)
        println("🔍 Found $(length(keys)) configured entries in $dir")

        existing = existing_files_by_key(dir)
        mkpath(dir)
        for key in keys
            value = get_value(c, dir, key)
            file = get(existing, key, joinpath(dir, "$key.txt"))
            current = isfile(file) ? read(file, String) : nothing
            if current != value
                write(file, value)
                println("📝 $(isnothing(current) ? "Added" : "Updated") $file")
            else
                println("✅ Unchanged $file")
            end
        end

        # Remove files whose entries are no longer configured on Discourse
        for (key, file) in existing
            if key ∉ keys
                rm(file)
                println("🗑️  Removed $file (no longer configured)")
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Push: apply committed changes to the live site

git(args...) = readchomp(Cmd(["git", args...]))

# The commit range whose diff should be applied to Discourse. The pull job
# runs after every push, keeping main's tip in step with the live state, so
# the triggering event's own range is exactly what remains to apply.
function diff_range(deploy::Bool)
    if deploy
        before = get(ENV, "BEFORE_SHA", "")
        return "$(isempty(before) || all(==('0'), before) ? "HEAD~1" : before)..HEAD"
    end
    # Pull request dry run: everything the PR would add to its base
    return "$(ENV["PR_BASE_SHA"])...$(ENV["PR_HEAD_SHA"])"
end

"""
    file_changes(range) -> Vector{Pair{String,Union{String,Nothing}}}

The changed files in the git commit `range` paired with their new contents
(read from the working tree, i.e. the range tip), where `nothing` indicates
a deletion. Only files on routes under `admin/` are considered; dotfiles
are ignored.
"""
function file_changes(range)
    changes = Pair{String,Union{String,Nothing}}[]
    for line in eachsplit(git("diff", "--name-status", "--no-renames", range), '\n'; keepempty = false)
        status, file = split(line, '\t')
        parts = splitpath(file)
        (length(parts) < 2 || first(parts) != "admin" || any(startswith("."), parts)) && continue
        push!(changes, String(file) => status == "D" ? nothing : read(String(file), String))
    end
    return changes
end

"""
    apply!(c::Union{Client,Nothing}, changes; deploy)

Apply `changes` (as returned by [`file_changes`](@ref)) to each file's
namesake route, or just print them when `deploy=false`.
"""
function apply!(c::Union{Client,Nothing}, changes; deploy::Bool)
    println("\n🔍 Sending $(length(changes)) updates:")
    println("━"^40)

    for (file, content) in changes
        dir = dirname(file)
        key = key_for_file(file)

        if isnothing(content)
            # Deleting the file reverts the entry to the Discourse default
            println("🗑️  REVERT: $file → DELETE $key\n")
            if deploy
                reset_value!(c, dir, key)
                println("✅ Reverted $file")
            end
        else
            println("📝 UPDATE: $file → PUT $key")
            println("   Value: $(repr(content))\n")
            if deploy
                set_value!(c, dir, key, content)
                println("✅ Updated $file")
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Workflow entry points

fail(msg) = (println(stderr, "❌ $msg"); exit(1))

"""
    main_pull()

Workflow entry point: mirror the live Discourse state into the repository.
"""
function main_pull()
    try
        pull!(client_from_env())
    catch e
        e isa ErrorException ? fail(e.msg) : rethrow()
    end
end

"""
    main_push()

Workflow entry point: apply the newly-pushed changes to the live Discourse
site, or just dry-run them on a pull request. The workflow separately
verifies that the pre-change state still matches the live one before
running this.
"""
function main_push()
    try
        deploy = get(ENV, "GITHUB_EVENT_NAME", "") == "push"
        println("🚀 Running in $(deploy ? "LIVE" : "DRY RUN") mode")

        range = diff_range(deploy)
        println("Diffing $range")
        changes = file_changes(range)
        if isempty(changes)
            println("No file changes detected")
            return
        end
        apply!(deploy ? client_from_env() : nothing, changes; deploy)
    catch e
        e isa ErrorException ? fail(e.msg) : rethrow()
    end
end

end # module
