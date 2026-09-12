using DiscourseAdmin
using DiscourseAdmin: singular, entry_for, config_routes, existing_files, available_locales,
                      configured_keys, get_value, set_value!, reset_value!,
                      pull!, file_changes, apply!, diff_range
using HTTP
using JSON
using Test

# ---------------------------------------------------------------------------
# A mock Discourse instance: per-locale site text overrides (rejecting
# locale-less requests, like the real one), a locale-less "mock_things"
# route, and the site settings listing the available locales. The site
# texts listing paginates like the real one (but with a tiny page size so
# the tests routinely cross page boundaries).

const PAGE_SIZE = 2
const LAST_PUT_LOCALE = Ref("")

function query_params(target)
    parts = split(target, '?'; limit = 2)
    length(parts) == 1 && return Dict{String,String}()
    return Dict(String(k) => HTTP.unescapeuri(v)
                for (k, v) in (split(kv, '='; limit = 2) for kv in split(parts[2], '&')))
end

parse_form(body) = Dict(HTTP.unescapeuri(k) => HTTP.unescapeuri(v)
                        for (k, v) in (split(kv, '='; limit = 2) for kv in split(body, '&')))

function mock_discourse(state::Dict{String,Dict{String,String}}, things::Dict{String,String}, port)
    st = "/admin/customize/site_texts"
    mt = "/admin/mock_things"
    return HTTP.serve!("127.0.0.1", port) do req
        path = first(split(req.target, '?'))
        qp = query_params(req.target)

        if path == "/admin/site_settings.json"
            return HTTP.Response(200, JSON.json(Dict("site_settings" => [
                Dict("setting" => "title", "value" => "x"),
                Dict("setting" => "default_locale", "value" => "en",
                     "valid_values" => [Dict("value" => l) for l in ("en", "fr", "pt_BR")])])))
        end

        if startswith(path, st)
            # like the real site texts API, every action requires a locale
            locale = req.method == "PUT" ? get(parse_form(String(req.body)), "site_text[locale]", "") :
                                           get(qp, "locale", "")
            isempty(locale) && return HTTP.Response(400, "invalid locale")
            texts = get!(state, locale, Dict{String,String}())
            if req.method == "GET" && path == "$st.json"
                ks = sort!(collect(keys(texts)))
                page = parse(Int, get(qp, "page", "0"))
                pageks = ks[min(page * PAGE_SIZE + 1, end + 1):min((page + 1) * PAGE_SIZE, end)]
                return HTTP.Response(200, JSON.json(Dict(
                    "site_texts" => [Dict("id" => k, "overridden" => true) for k in pageks],
                    "extras" => Dict("has_more" => length(ks) > (page + 1) * PAGE_SIZE))))
            end
            key = HTTP.unescapeuri(replace(chopprefix(path, "$st/"), r"\.json$" => ""))
            if req.method == "GET"
                haskey(texts, key) || return HTTP.Response(404, "no such site text")
                return HTTP.Response(200, JSON.json(Dict("site_text" => Dict("id" => key, "value" => texts[key]))))
            elseif req.method == "PUT"
                LAST_PUT_LOCALE[] = locale
                texts[key] = parse_form(String(req.body))["site_text[value]"]
                return HTTP.Response(200, JSON.json(Dict("site_text" => Dict("id" => key, "value" => texts[key]))))
            elseif req.method == "DELETE"
                haskey(texts, key) || return HTTP.Response(404, "no such site text")
                delete!(texts, key)
                return HTTP.Response(200, "reverted")
            end
        end

        if startswith(path, mt)
            # a locale-less route: the locale parameter is simply ignored
            if req.method == "GET" && path == "$mt.json"
                return HTTP.Response(200, JSON.json(Dict(
                    "mock_things" => [Dict("id" => k) for k in sort!(collect(keys(things)))],
                    "extras" => Dict("has_more" => false))))
            end
            key = HTTP.unescapeuri(replace(chopprefix(path, "$mt/"), r"\.json$" => ""))
            req.method == "GET" && return haskey(things, key) ?
                HTTP.Response(200, JSON.json(Dict("mock_thing" => Dict("value" => things[key])))) :
                HTTP.Response(404, "no such thing")
            if req.method == "PUT"
                things[key] = parse_form(String(req.body))["mock_thing[value]"]
                return HTTP.Response(200, "ok")
            end
        end

        return HTTP.Response(405, "unsupported")
    end
end

const PORT = 8397
const ROUTE = "admin/customize/site_texts"
state = Dict{String,Dict{String,String}}()
things = Dict{String,String}()
server = mock_discourse(state, things, PORT)
client = Client(base_url = "http://127.0.0.1:$PORT", api_key = "test-key", api_user = "test-user")

en() = get!(state, "en", Dict{String,String}())
fr() = get!(state, "fr", Dict{String,String}())

git(args...; dir) = readchomp(setenv(Cmd(["git", args...]); dir))

function init_test_repo(dir)
    for args in (["init", "-q"], ["config", "user.name", "test"], ["config", "user.email", "t@t"])
        git(args...; dir)
    end
end

@testset "DiscourseAdmin" begin
    @testset "conventions" begin
        # a locale-shaped filename is one translation of its parent-directory key
        @test entry_for("$ROUTE/guidelines_topic.body/en.md") == (ROUTE, "guidelines_topic.body", "en")
        @test entry_for("$ROUTE/some.dotted.key/pt_BR.txt") == (ROUTE, "some.dotted.key", "pt_BR")
        @test entry_for("$ROUTE/welcome/en-GB.txt") == (ROUTE, "welcome", "en-GB")
        # any other filename is itself the key of a locale-less entry
        @test entry_for("admin/site_settings/title.txt") == ("admin/site_settings", "title", nothing)
        @test entry_for("admin/site_settings/some.dotted.key.txt") == ("admin/site_settings", "some.dotted.key", nothing)

        # the form/JSON name is the singular of the route's last segment
        @test singular(ROUTE) == "site_text"
        @test singular("admin/site_settings") == "site_setting"

        mktempdir() do dir
            cd(dir) do
                # routes are declared by entry files or bare dotfiles; content
                # outside admin/ (like the package itself) is out of scope
                mkpath("$ROUTE/one.key"); write("$ROUTE/one.key/en.txt", "x")
                mkpath("admin/mock_things"); write("admin/mock_things/.gitkeep", "")
                mkpath("DiscourseAdmin/src"); write("DiscourseAdmin/src/pkg.jl", "x")
                @test config_routes() == [ROUTE, "admin/mock_things"]
                @test existing_files(ROUTE, "en") == Dict("one.key" => "$ROUTE/one.key/en.txt")
                @test isempty(existing_files(ROUTE, "fr"))
                @test isempty(existing_files(ROUTE, nothing))
            end
        end
    end

    @testset "admin API client" begin
        empty!(state)
        en()["one.key"] = "hello"
        en()["guidelines_topic.body"] = "## Guidelines\n"
        fr()["one.key"] = "bonjour"

        @test available_locales(client) == ["en", "fr", "pt_BR"]

        @test sort(configured_keys(client, ROUTE; locale = "en")) == ["guidelines_topic.body", "one.key"]
        @test configured_keys(client, ROUTE; locale = "fr") == ["one.key"]
        @test_throws HTTP.StatusError configured_keys(client, ROUTE)  # locale required
        @test get_value(client, ROUTE, "one.key"; locale = "en") == "hello"
        @test get_value(client, ROUTE, "one.key"; locale = "fr") == "bonjour"

        set_value!(client, ROUTE, "one.key", "changed & escaped=safely\n"; locale = "en")
        @test en()["one.key"] == "changed & escaped=safely\n"
        @test LAST_PUT_LOCALE[] == "en"  # required by the site texts API

        reset_value!(client, ROUTE, "one.key"; locale = "en")
        @test !haskey(en(), "one.key")
        @test fr()["one.key"] == "bonjour"
    end

    @testset "configured_keys follows pagination" begin
        empty!(state)
        for i in 1:(3PAGE_SIZE + 1)  # 4 pages, the last one partial
            en()["key.$i"] = "value $i"
        end
        @test sort(configured_keys(client, ROUTE; locale = "en")) == sort!(collect(keys(en())))
    end

    @testset "pull! mirrors every locale of the live state" begin
        empty!(state)
        empty!(things)
        en()["one.key"] = "v1 header"
        en()["added.body"] = "a newly-overridden entry"
        en()["doc.key"] = "markdown content"
        fr()["one.key"] = "entête v1"
        things["thing.a"] = "a value"

        mktempdir() do dir
            cd(dir) do
                # a bare .gitkeep is all a route needs
                mkpath(ROUTE); write("$ROUTE/.gitkeep", "")
                mkpath("admin/mock_things"); write("admin/mock_things/.gitkeep", "")
                mkpath("$ROUTE/one.key"); write("$ROUTE/one.key/en.txt", "stale value")
                mkpath("$ROUTE/doc.key"); write("$ROUTE/doc.key/en.md", "markdown content")
                mkpath("$ROUTE/removed.key"); write("$ROUTE/removed.key/en.txt", "no longer overridden")

                pull!(client)

                @test read("$ROUTE/one.key/en.txt", String) == "v1 header"
                @test read("$ROUTE/one.key/fr.txt", String) == "entête v1"  # all locales, unprompted
                @test read("$ROUTE/doc.key/en.md", String) == "markdown content" # extension preserved
                @test read("$ROUTE/added.body/en.txt", String) == "a newly-overridden entry"
                # a removed entry loses its file and its emptied key directory
                @test !isdir("$ROUTE/removed.key")
                # dotfiles are not mirror content and survive untouched
                @test isfile("$ROUTE/.gitkeep")
                @test sort(readdir(ROUTE)) == [".gitkeep", "added.body", "doc.key", "one.key"]
                # the locale-less route mirrors flat files
                @test read("admin/mock_things/thing.a.txt", String) == "a value"
            end
        end
    end

    @testset "file_changes and diff_range" begin
        mktempdir() do dir
            cd(dir) do
                init_test_repo(dir)
                mkpath("$ROUTE/one.key")
                write("$ROUTE/one.key/en.txt", "v1")
                write("$ROUTE/.gitkeep", "")
                write("README.md", "root files are ignored")
                mkpath(".github"); write(".github/dotdirs-are-ignored.txt", "x")
                mkpath("DiscourseAdmin/src"); write("DiscourseAdmin/src/pkg.jl", "# v1")
                git("add", "-A"; dir); git("commit", "-qm", "c1"; dir)
                c1 = git("rev-parse", "HEAD"; dir)

                write("$ROUTE/one.key/en.txt", "v2")
                mkpath("$ROUTE/two.key"); write("$ROUTE/two.key/en.txt", "new")
                write("DiscourseAdmin/src/pkg.jl", "# v2")  # outside admin/: never synced
                git("add", "-A"; dir); git("commit", "-qm", "c2"; dir)

                # contents are read from the working tree, i.e. the range tip
                @test sort(file_changes("$c1..HEAD"); by = first) ==
                      ["$ROUTE/one.key/en.txt" => "v2", "$ROUTE/two.key/en.txt" => "new"]

                rm("$ROUTE/two.key"; recursive = true)
                git("add", "-A"; dir); git("commit", "-qm", "c3"; dir)
                c3 = git("rev-parse", "HEAD"; dir)

                # two.key was added then deleted, so it nets out of the full span
                @test file_changes("$c1..$c3") == ["$ROUTE/one.key/en.txt" => "v2"]
                @test file_changes("HEAD~1..HEAD") == ["$ROUTE/two.key/en.txt" => nothing]

                # deploy ranges come from the push event's before sha, with a
                # fallback for events with no valid one (e.g. a new branch)
                withenv("BEFORE_SHA" => c1) do
                    @test diff_range(true) == "$c1..HEAD"
                end
                withenv("BEFORE_SHA" => "0"^40) do
                    @test diff_range(true) == "HEAD~1..HEAD"
                end
                withenv("PR_BASE_SHA" => c1, "PR_HEAD_SHA" => c3) do
                    @test diff_range(false) == "$c1...$c3"
                end
            end
        end
    end

    @testset "apply!" begin
        empty!(state)
        en()["one.key"] = "old"
        changes = ["$ROUTE/one.key/en.txt" => "new value",
                   "$ROUTE/gone.key/en.txt" => nothing]

        # dry run touches nothing
        apply!(nothing, changes; deploy = false)
        @test en() == Dict("one.key" => "old")

        en()["gone.key"] = "x"
        apply!(client, changes; deploy = true)
        @test en() == Dict("one.key" => "new value")
        @test LAST_PUT_LOCALE[] == "en"  # derived from the filename
    end
end

close(server)
