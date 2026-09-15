"""
    DiscourseAdmin

A simple package to manage Discourse `admin` configuration.

This treats the admin settings as a simple key/value store.
The values are contents of files, and the `admin/**` path is the API
route. An entry on a localized route is `route/key/locale.ext` (e.g.
`admin/customize/site_texts/guidelines_topic.body/en.md`); an entry on
a locale-less route is simply `route/key.ext`. The extension is only
for display on GitHub. Pulling mirrors every locale the site has
entries in, so a new route needs nothing but its (`.gitkeep`-held)
directory.

The two CLI entry points used by the GitHub workflows are
[`main_pull`](@ref) (mirror the live state into the repository) and
[`main_push`](@ref) (apply committed changes to the live site).
"""
module DiscourseAdmin

using HTTP
using JSON

export Client

const DEFAULT_BASE_URL = "https://discourse.julialang.org"

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
singular(route) = chopsuffix(basename(route), "s")

endpoint(c::Client, route, key = nothing) =
    "$(c.base_url)/$route$(isnothing(key) ? "" : "/$(HTTP.escapeuri(key))")"

# The site texts API requires an explicit locale on every request; routes
# without locale support simply have none to send.
locale_query(locale) = isnothing(locale) ? Pair{String,String}[] : ["locale" => locale]

"""
    configured_keys(c::Client, route; locale=nothing) -> Vector{String}

The keys of every entry currently configured on the `route` endpoint,
following `extras.has_more` pagination through the `page` parameter.
"""
function configured_keys(c::Client, route; locale = nothing)
    keys = String[]
    page = 0
    while true
        resp = HTTP.get("$(endpoint(c, route)).json";
                        query = [["overridden" => "true", "page" => string(page)];
                                 locale_query(locale)],
                        headers = auth_headers(c))
        data = JSON.parse(String(resp.body))
        append!(keys, String[t["id"] for t in data[basename(route)]])
        get(get(data, "extras", Dict()), "has_more", false) || return keys
        page += 1
    end
end

"""
    get_value(c::Client, route, key; locale=nothing) -> String

The currently-configured value of `key` on the `route` endpoint.
"""
function get_value(c::Client, route, key; locale = nothing)
    resp = HTTP.get("$(endpoint(c, route, key)).json";
                    query = locale_query(locale), headers = auth_headers(c))
    return JSON.parse(String(resp.body))[singular(route)]["value"]::String
end

"""
    set_value!(c::Client, route, key, value; locale=nothing)

Create or update the configuration of `key` on the `route` endpoint.
"""
function set_value!(c::Client, route, key, value; locale = nothing)
    form = ["$(singular(route))[value]" => value]
    isnothing(locale) || push!(form, "$(singular(route))[locale]" => locale)
    HTTP.put(endpoint(c, route, key);
             headers = [auth_headers(c);
                        "Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8"],
             body = HTTP.escapeuri(form))
    return nothing
end

"""
    reset_value!(c::Client, route, key; locale=nothing)

Remove the configuration of `key`, reverting it to the Discourse default.
"""
function reset_value!(c::Client, route, key; locale = nothing)
    HTTP.delete(endpoint(c, route, key);
                query = locale_query(locale), headers = auth_headers(c))
    return nothing
end

# ---------------------------------------------------------------------------
# Repository conventions

# Extensions are only for display on GitHub; strip them to find the name
const DISPLAY_EXTENSION = r"\.(txt|md|json)$"
const LOCALE_SHAPE = r"^[a-z]{2}([_-][A-Za-z]{2})?$"

"""
    entry_for(file) -> (route, key, locale)

The API entry a repository file manages. A filename shaped like a locale
(`en`, `pt_BR`, `en-GB`) holds one translation of the key named by its
parent directory (`route/key/locale.ext`); any other filename is itself the
key of a locale-less entry (`route/key.ext`), with `locale === nothing`.
"""
function entry_for(file)
    name = replace(basename(file), DISPLAY_EXTENSION => "")
    occursin(LOCALE_SHAPE, name) && return (dirname(dirname(file)), basename(dirname(file)), name)
    return (dirname(file), name, nothing)
end

"""
    config_routes(root="admin") -> Vector{String}

The API routes the repository mirrors, declared by the files present: an
entry file declares its own route, and a dotfile (like a `.gitkeep`
holding an otherwise-empty route directory) declares its containing
directory.
"""
function config_routes(root = "admin")
    routes = Set{String}()
    isdir(root) || return String[]
    for (path, _, files) in walkdir(root), f in files
        push!(routes, startswith(f, ".") ? path : entry_for(joinpath(path, f))[1])
    end
    return sort!(collect(routes))
end

# Map each key of a (route, locale) pair to its on-disk file, so an existing
# file's display extension is preserved when its value is updated.
function existing_files(route, locale)
    bykey = Dict{String,String}()
    isdir(route) || return bykey
    for (path, _, files) in walkdir(route), f in files
        startswith(f, ".") && continue
        file = joinpath(path, f)
        r, key, loc = entry_for(file)
        r == route && loc == locale && (bykey[key] = file)
    end
    return bykey
end

# ---------------------------------------------------------------------------
# Pull: mirror the live state into the repository

"""
    available_locales(c::Client) -> Vector{String}

Every locale the instance supports, read from the `default_locale` site
setting's valid values.
"""
function available_locales(c::Client)
    resp = HTTP.get("$(c.base_url)/admin/site_settings.json"; headers = auth_headers(c))
    settings = JSON.parse(String(resp.body))["site_settings"]
    i = findfirst(s -> s["setting"] == "default_locale", settings)
    isnothing(i) && error("could not determine the available locales from the site settings")
    return String[v["value"] for v in settings[i]["valid_values"]]
end

# Of all the admin routes, only site_texts requires (and localizes by) a
# locale parameter; every other route ignores it.
localized(route) = basename(route) == "site_texts"

"""
    pull!(c::Client, routes=config_routes())

Mirror the live configuration of each route into its files, adding,
updating, and removing them so the repository exactly reflects the live
state. A [`localized`](@ref) route is mirrored for every locale the site
has entries in.
"""
function pull!(c::Client, routes = config_routes())
    for route in routes
        if localized(route)
            # mirror every locale with configured entries (or with
            # lingering files to clean up)
            for locale in available_locales(c)
                keys = configured_keys(c, route; locale)
                isempty(keys) && isempty(existing_files(route, locale)) && continue
                mirror!(c, route, locale, keys)
            end
        else
            mirror!(c, route, nothing)
        end
    end
    return nothing
end

function mirror!(c::Client, route, locale, keys = configured_keys(c, route; locale))
    println("🔍 Found $(length(keys)) configured entries in $route$(isnothing(locale) ? "" : " ($locale)")")

    existing = existing_files(route, locale)
    for key in keys
        value = get_value(c, route, key; locale)
        file = get(existing, key) do
            isnothing(locale) ? joinpath(route, "$key.txt") : joinpath(route, key, "$locale.txt")
        end
        current = isfile(file) ? read(file, String) : nothing
        if current != value
            mkpath(dirname(file))
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
            # and the key directory, once its last translation is gone
            dir = dirname(file)
            dir != route && isempty(readdir(dir)) && rm(dir)
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Push: apply committed changes to the live site

git(args...) = readchomp(Cmd(["git", args...]))

# The commit range whose diff should be applied to Discourse. The pull job
# runs after every push, keeping main's tip in step with the live state, so
# the push event's own range is exactly what remains to apply.
function diff_range()
    before = get(ENV, "BEFORE_SHA", "")
    return "$(isempty(before) || all(==('0'), before) ? "HEAD~1" : before)..HEAD"
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
    apply!(c::Client, changes)

Apply `changes` (as returned by [`file_changes`](@ref)) to each file's
namesake entry.
"""
function apply!(c::Client, changes)
    println("🔍 Sending $(length(changes)) updates:")
    for (file, content) in changes
        route, key, locale = entry_for(file)
        if isnothing(content)
            # Deleting the file reverts the entry to the Discourse default
            reset_value!(c, route, key; locale)
            println("🗑️  Reverted $file")
        else
            set_value!(c, route, key, content; locale)
            println("✅ Updated $file")
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
site. The workflow separately verifies that the pre-change state still
matches the live one before running this.
"""
function main_push()
    try
        range = diff_range()
        println("Diffing $range")
        changes = file_changes(range)
        if isempty(changes)
            println("No file changes detected")
            return
        end
        apply!(client_from_env(), changes)
    catch e
        e isa ErrorException ? fail(e.msg) : rethrow()
    end
end

end # module
