using DiscourseAdmin
using DiscourseAdmin: singular, config_dirs, key_for_file, configured_keys, get_value,
                      set_value!, reset_value!, pull!, file_changes,
                      apply!, diff_range
using HTTP
using JSON
using Test

# ---------------------------------------------------------------------------
# A mock Discourse instance backed by a Dict of key => value overrides,
# paginating its listing like the real one (but with a tiny page size so the
# tests routinely cross page boundaries)

const PAGE_SIZE = 2

function query_params(target)
    parts = split(target, '?'; limit = 2)
    length(parts) == 1 && return Dict{String,String}()
    return Dict(String(k) => HTTP.unescapeuri(v)
                for (k, v) in (split(kv, '='; limit = 2) for kv in split(parts[2], '&')))
end

function mock_discourse(state::Dict{String,String}, port)
    prefix = "/admin/customize/site_texts"
    return HTTP.serve!("127.0.0.1", port) do req
        path = first(split(req.target, '?'))
        if req.method == "GET" && path == "$prefix.json"
            ks = sort!(collect(keys(state)))
            page = parse(Int, get(query_params(req.target), "page", "0"))
            pageks = ks[min(page * PAGE_SIZE + 1, end + 1):min((page + 1) * PAGE_SIZE, end)]
            return HTTP.Response(200, JSON.json(Dict(
                "site_texts" => [Dict("id" => k, "overridden" => true) for k in pageks],
                "extras" => Dict("has_more" => length(ks) > (page + 1) * PAGE_SIZE))))
        end
        key = HTTP.unescapeuri(replace(chopprefix(path, "$prefix/"), r"\.json$" => ""))
        if req.method == "GET"
            haskey(state, key) || return HTTP.Response(404, "no such site text")
            return HTTP.Response(200, JSON.json(Dict("site_text" => Dict("id" => key, "value" => state[key]))))
        elseif req.method == "PUT"
            form = Dict(HTTP.unescapeuri(k) => HTTP.unescapeuri(v)
                        for (k, v) in (split(kv, '='; limit = 2) for kv in split(String(req.body), '&')))
            state[key] = form["site_text[value]"]
            return HTTP.Response(200, JSON.json(Dict("site_text" => Dict("id" => key, "value" => state[key]))))
        elseif req.method == "DELETE"
            haskey(state, key) || return HTTP.Response(404, "no such site text")
            delete!(state, key)
            return HTTP.Response(200, "reverted")
        end
        return HTTP.Response(405, "unsupported")
    end
end

const PORT = 8397
state = Dict{String,String}()
server = mock_discourse(state, PORT)
client = Client(base_url = "http://127.0.0.1:$PORT", api_key = "test-key", api_user = "test-user")

git(args...; dir) = readchomp(setenv(Cmd(["git", args...]); dir))

function init_test_repo(dir)
    for args in (["init", "-q"], ["config", "user.name", "test"], ["config", "user.email", "t@t"])
        git(args...; dir)
    end
end

@testset "DiscourseAdmin" begin
    @testset "conventions" begin
        # the form/JSON name is the singular of the route's last segment
        @test singular("admin/customize/site_texts") == "site_text"

        @test key_for_file("admin/customize/site_texts/some.dotted.key.txt") == "some.dotted.key"
        @test key_for_file("admin/customize/site_texts/instructions.md") == "instructions"
        # Keys contain dots that are not display extensions and must survive
        @test key_for_file("admin/customize/site_texts/guidelines_topic.body") == "guidelines_topic.body"
        @test key_for_file("admin/customize/site_texts/guidelines_topic.body.txt") == "guidelines_topic.body"

        mktempdir() do dir
            cd(dir) do
                # only leaf directories under admin/ are routes; the package
                # itself and other top-level content are out of scope
                mkpath("admin/customize/site_texts")
                mkpath("DiscourseAdmin/src"); mkpath(".github"); write("README.md", "x")
                @test config_dirs() == ["admin/customize/site_texts"]
            end
        end
    end

    @testset "admin API client" begin
        empty!(state)
        state["one.key"] = "hello"
        state["guidelines_topic.body"] = "## Guidelines\n"

        @test sort(configured_keys(client, "admin/customize/site_texts")) == ["guidelines_topic.body", "one.key"]
        @test get_value(client, "admin/customize/site_texts", "one.key") == "hello"
        @test get_value(client, "admin/customize/site_texts", "guidelines_topic.body") == "## Guidelines\n"

        set_value!(client, "admin/customize/site_texts", "one.key", "changed & escaped=safely\n")
        @test state["one.key"] == "changed & escaped=safely\n"

        reset_value!(client, "admin/customize/site_texts", "one.key")
        @test !haskey(state, "one.key")
    end

    @testset "configured_keys follows pagination" begin
        empty!(state)
        for i in 1:(3PAGE_SIZE + 1)  # 4 pages, the last one partial
            state["key.$i"] = "value $i"
        end
        @test sort(configured_keys(client, "admin/customize/site_texts")) == sort!(collect(keys(state)))
    end

    @testset "pull! mirrors the live state" begin
        empty!(state)
        state["one.key"] = "v1 header"
        state["extensionless.body"] = "no display extension yet"
        state["doc.key"] = "markdown content"

        mktempdir() do dir
            cd(dir) do
                mkpath("admin/customize/site_texts")
                write("admin/customize/site_texts/.gitkeep", "")
                write("admin/customize/site_texts/one.key.txt", "stale value")
                write("admin/customize/site_texts/doc.key.md", "markdown content")
                write("admin/customize/site_texts/removed.key.txt", "no longer overridden")

                pull!(client)

                @test read("admin/customize/site_texts/one.key.txt", String) == "v1 header"
                @test read("admin/customize/site_texts/doc.key.md", String) == "markdown content" # extension preserved
                @test read("admin/customize/site_texts/extensionless.body.txt", String) == "no display extension yet"
                @test !isfile("admin/customize/site_texts/removed.key.txt")
                # dotfiles are not mirror content and survive untouched
                @test sort(readdir("admin/customize/site_texts")) ==
                      [".gitkeep", "doc.key.md", "extensionless.body.txt", "one.key.txt"]
            end
        end
    end

    @testset "file_changes and diff_range" begin
        empty!(state)
        mktempdir() do dir
            cd(dir) do
                init_test_repo(dir)
                mkpath("admin/customize/site_texts")
                write("admin/customize/site_texts/one.key.txt", "v1")
                write("admin/customize/site_texts/.gitkeep", "")
                write("README.md", "root files are ignored")
                mkpath(".github"); write(".github/dotdirs-are-ignored.txt", "x")
                mkpath("DiscourseAdmin/src"); write("DiscourseAdmin/src/pkg.jl", "# v1")
                git("add", "-A"; dir); git("commit", "-qm", "c1"; dir)
                c1 = git("rev-parse", "HEAD"; dir)

                write("admin/customize/site_texts/one.key.txt", "v2")
                write("admin/customize/site_texts/two.key.txt", "new")
                write("DiscourseAdmin/src/pkg.jl", "# v2")  # outside admin/: never synced
                git("add", "-A"; dir); git("commit", "-qm", "c2"; dir)

                # contents are read from the working tree, i.e. the range tip
                @test sort(file_changes("$c1..HEAD"); by = first) ==
                      ["admin/customize/site_texts/one.key.txt" => "v2", "admin/customize/site_texts/two.key.txt" => "new"]

                rm("admin/customize/site_texts/two.key.txt")
                rm("admin/customize/site_texts/.gitkeep")  # dotfile changes never reach the API
                git("add", "-A"; dir); git("commit", "-qm", "c3"; dir)
                c3 = git("rev-parse", "HEAD"; dir)

                # two.key was added then deleted, so it nets out of the full span
                @test file_changes("$c1..$c3") == ["admin/customize/site_texts/one.key.txt" => "v2"]
                @test file_changes("HEAD~1..HEAD") == ["admin/customize/site_texts/two.key.txt" => nothing]

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
        state["one.key"] = "old"
        changes = ["admin/customize/site_texts/one.key.txt" => "new value",
                   "admin/customize/site_texts/gone.key.txt" => nothing]

        # dry run touches nothing
        apply!(nothing, changes; deploy = false)
        @test state == Dict("one.key" => "old")

        state["gone.key"] = "x"
        apply!(client, changes; deploy = true)
        @test state == Dict("one.key" => "new value")
    end
end

close(server)
