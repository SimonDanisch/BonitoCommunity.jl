# The app on a real (worker-less) ServerState, driven through the same tool
# requests BonitoMCP sends. Like BonitoAgents' own `unit:app_platform` test, it
# builds the server from BonitoAgents internals. The network is stubbed: the
# Mastodon methods are replaced by ones that record what they were asked.
using Test, Dates
import HTTP, JSON
using BonitoAgents, BonitoCommunity
const BT = BonitoAgents
const CM = BonitoCommunity
const PIN = "test community pin"

# What the stubbed Mastodon was asked to do, and the replies it hands out.
const NET = (posted = Any[], reposted = Any[], answered = Any[], replies = Any[], mentions = Any[])
@eval CM begin
    verify_account(::Mastodon, a::Account, secret::AbstractString) =
        secret == "good" ? nothing : throw(AppError("GET /api/v1/accounts/verify_credentials failed (401): invalid token"))
    publish(::Mastodon, app::CommunityApp, a::Account, ::Draft, text::AbstractString) =
        (push!($NET.posted, (a.id, text)); Post(a.id, "original", "101", "", "https://fosstodon.org/@m4s/101", now(UTC)))
    repost(::Mastodon, app::CommunityApp, a::Account, original::Post) =
        (push!($NET.reposted, (a.id, original.ref)); Post(a.id, "repost", "202", "", original.url, now(UTC)))
    fetch_replies(::Mastodon, app::CommunityApp, a::Account, post::Post) = copy($NET.replies)
    fetch_stats(::Mastodon, app::CommunityApp, a::Account, post::Post) = Dict("likes" => 12, "reposts" => 3, "replies" => 1)
    send_answer(::Mastodon, app::CommunityApp, a::Account, to::AnswerTo, text::AbstractString) =
        (push!($NET.answered, (a.id, to.post, text)); nothing)
    fetch_mentions(::Mastodon, app::CommunityApp, a::Account) = a.brand == "Makie" ? copy($NET.mentions) : NamedTuple[]
end

function test_server()
    state_dir = mktempdir()
    projects = mktempdir()
    app_dir = joinpath(state_dir, "apps", "community")
    mkpath(app_dir)
    BT.atomic_write_json(joinpath(app_dir, "settings.json"), CM.Settings(projects, CM.DEFAULT_BRANDS, CM.Watch[], "private"))
    server = BT.ServerState(; state_dir, working_dir = mktempdir(), apps = (CommunityApp,))
    server.workers[]["w"] = BT.WorkerInfo("w", "Desk", nothing, "h", "/home/u", "julia", String[],
                                          "/home/u/p", :online, now())
    overview = BT.add_project!(server, BT.ProjectInfo("c1", "community", "w", mktempdir(), "/home/u/p/community", now(UTC)))
    overview.app = "community"
    app = server.apps["community"]
    CM.create_vault!(app, PIN)
    return server, app, projects
end

# `caller` is the calling chat (its ProjectInfo); the request names it by id.
tools(server, caller) = [t["name"] for t in BT.dev_request(server, "app_tools", Dict{String,Any}(), caller.id)]
function call(server, caller, tool; args...)
    r = BT.dev_request(server, "app_call", Dict{String,Any}("tool" => tool,
        "args" => Dict{String,Any}(String(k) => v for (k, v) in args)), caller.id)
    return r["result"]["content"][1]["text"]
end

# Field by field, into vectors: the state's structs hold vectors and dicts, which `==` on a struct doesn't look into.
same(a, b) = a isa AbstractVector ? length(a) == length(b) && all(splat(same), zip(a, b)) :
             a isa Union{CM.Project,CM.Draft,CM.Post,CM.Reply,CM.InboxItem,CM.Account} ?
                 all(f -> same(getfield(a, f), getfield(b, f)), fieldnames(typeof(a))) : a == b

@testset "BonitoCommunity" begin
    server, app, projects = test_server()
    app.poller === nothing || close(app.poller)   # the test drives the checks itself

    @testset "dashboard includes every platform" begin
        data = CM.dashboard_data(CM.Dashboard(app, nothing, ""), app.state[], "")
        @test Set(p["id"] for p in data["platforms"]) == Set(CM.platform_id.(CM.PLATFORMS))
        @test only(filter(p -> p["id"] == "discourse", data["platforms"]))["color"] == "#9558b2"
    end

    @testset "platforms" begin
        @test CM.find_platform("Bluesky") === CM.Bluesky()
        @test_throws BT.AppError CM.find_platform("myspace")
        @test CM.text_length(CM.Bluesky(), "watch: {youtube_url}") == length("watch: https://youtu.be/xxxxxxxxxxx")
        @test CM.text_length(CM.Bluesky(), "🕳️ x") == 3     # graphemes, not characters
        @test_throws BT.AppError CM.check_draft_text(CM.Bluesky(), "", "x"^301)
        @test_throws BT.AppError CM.check_draft_text(CM.Mastodon(), "a title", "text")
        @test CM.check_draft_text(CM.YouTube(), "A title", "desc") === nothing
        @test CM.check_draft_text(CM.Discourse(), "BonitoAgents is here", "A Markdown release announcement.") === nothing
        @test_throws BT.AppError CM.check_draft_text(CM.Discourse(), "x"^121, "body")
        @test_throws BT.AppError CM.check_draft_media(CM.Bluesky(), ["a.mp4"])
        @test CM.account_server(CM.Mastodon(), "makie@fosstodon.org", "") == "https://fosstodon.org"
        @test CM.account_server(CM.Bluesky(), "makie.org", "") == "https://bsky.social"
    end

    @testset "Bluesky facets: byte ranges of links, tags and mentions" begin
        text = "Black hole 🕳️ #julialang by @makie.org: https://youtu.be/abc#t=3 (#nope in the link)"
        facets = CM.bsky_facets(text; resolve = h -> h == "makie.org" ? "did:plc:makie" : nothing)
        byrange(f) = String(codeunits(text)[f["index"]["byteStart"]+1:f["index"]["byteEnd"]])
        kinds = [f["features"][1]["\$type"] for f in facets]
        @test [byrange(f) for f in facets] == ["#julialang", "@makie.org", "https://youtu.be/abc#t=3", "#nope"]
        @test kinds == ["app.bsky.richtext.facet#tag", "app.bsky.richtext.facet#mention",
                        "app.bsky.richtext.facet#link", "app.bsky.richtext.facet#tag"]
        @test facets[1]["features"][1]["tag"] == "julialang" && facets[2]["features"][1]["did"] == "did:plc:makie"
        # a handle that doesn't resolve stays text; a tag inside a link is the link's
        @test isempty(CM.bsky_facets("hi @nobody.example"; resolve = _ -> nothing))
        @test length(CM.bsky_facets("see https://x.org/#frag"; resolve = _ -> nothing)) == 1
        @test CM.html_text("<p>Hi <a href=\"x\">@m4s</a> &amp; thanks!</p><p>Second</p>") == "Hi @m4s & thanks!\n\nSecond"
    end

    @testset "projects: created, and found as folders" begin
        p = CM.new_project!(app, "Black hole render", ["makie4science", "Makie"], "Ray traced black hole")
        @test startswith(p.id, Dates.format(today(), "yyyy-mm") * "-black-hole-render")
        @test p.brands == ["Makie4Science", "Makie"] && isempty(p.links)
        @test isdir(joinpath(projects, p.id))
        @test_throws BT.AppError CM.new_project!(app, "Black hole render", ["Makie"], "")
        @test_throws BT.AppError CM.new_project!(app, "No brand", String[], "")
        mkdir(joinpath(projects, "2026-12-dropped-in"))
        CM.scan_projects!(app)
        @test any(q -> q.id == "2026-12-dropped-in" && q.title == "Dropped in" && q.state == "new", app.state[].projects)
        CM.rename_project!(app, "2026-12-dropped-in", " Makie 0.25 release ")
        @test CM.find_project(app, "2026-12-dropped-in").title == "Makie 0.25 release"
        @test_throws BT.AppError CM.rename_project!(app, "2026-12-dropped-in", "  ")
    end

    p = first(app.state[].projects)
    write(joinpath(projects, p.id, "render.mp4"), "fake video")

    @testset "tools by scope: the overview, and the project's own chat" begin
        overview = server.projects[]["c1"]
        @test Set(tools(server, overview)) == Set(["cm_projects", "cm_new_project", "cm_inbox", "cm_answer", "cm_start_project_chat"])
        @test occursin("render.mp4", call(server, overview, "cm_projects"))
        chat = BT.add_project!(server, BT.ProjectInfo("c2", p.title, "w", mktempdir(), joinpath(projects, p.id), now(UTC)))
        @test isempty(tools(server, chat))
        chat.app = "community"; chat.app_key = CM.project_key(p)
        CM.set_project!(app, p.id; chat = "c2", state = "drafting")
        @test Set(tools(server, chat)) ==
              Set(["project_info", "project_draft", "project_submit", "project_replies", "project_answer"])
        @test BT.app_chat(server, app).id == "c1"           # the project chat is not the app's chat
        @test occursin("Bluesky (≤ 300 chars)", call(server, chat, "project_info"))
        @test occursin("community project `$(p.id)`", BT.app_prompt_appendix(server, chat))
        @test occursin("Community app's overview", BT.app_prompt_appendix(server, overview))
    end

    chat = server.projects[]["c2"]

    @testset "drafts" begin
        r = call(server, chat, "project_draft"; brand = "Makie4Science", platform = "youtube", kind = "video",
                 title = "How to render a black hole", text = "Chapters:\n0:00 Intro", media = "render.mp4")
        @test occursin("Saved draft #1", r)
        @test occursin("Saved draft #2", call(server, chat, "project_draft"; brand = "Makie4Science", platform = "mastodon",
                                               kind = "post", text = "A black hole, rendered with Makie: {youtube_url} #julialang"))
        @test occursin("is not for Bonito", call(server, chat, "project_draft"; brand = "Bonito", platform = "bluesky",
                                                  kind = "post", text = "x"))
        @test occursin("does not post on TikTok", call(server, chat, "project_draft"; brand = "Makie",
                                                        platform = "tiktok", kind = "video", text = "x"))
        @test occursin("allows 300 characters", call(server, chat, "project_draft"; brand = "Makie",
                                                      platform = "bluesky", kind = "post", text = "x"^400))
        @test occursin("carry no media", call(server, chat, "project_draft"; brand = "Makie", platform = "bluesky",
                                               kind = "post", text = "x", media = "render.mp4"))
        @test occursin("not in the project folder", call(server, chat, "project_draft"; brand = "Makie4Science",
                                                         platform = "tiktok", kind = "video", text = "x", media = "nope.mp4"))
        CM.review_draft!(app, 2, "approved")
        CM.review_draft!(app, 1, "changes"; note = "shorter title")
        @test occursin("user's note: shorter title", call(server, chat, "project_info"))
        call(server, chat, "project_draft"; brand = "Makie4Science", platform = "youtube", kind = "video",
             title = "Black hole in Makie", text = "Chapters:\n0:00 Intro", media = "render.mp4", draft_id = 1)
        d1 = CM.find_draft(app, 1)
        @test d1.status == "draft" && d1.note == "" && d1.title == "Black hole in Makie"
        @test_throws BT.AppError CM.edit_draft_text!(app, 2, "y"^600)
        @test occursin("ready for review", call(server, chat, "project_submit"; message = "two drafts"))
        @test CM.find_project(app, p.id).state == "review"
    end

    @testset "accounts: checked with the platform, secrets apart" begin
        @test_throws BT.AppError CM.add_account_with_pin!(app, "mastodon", "Makie4Science", "m4s@fosstodon.org", "", "post", "bad", PIN)
        a = CM.add_account_with_pin!(app, "mastodon", "Makie4Science", "@m4s@fosstodon.org", "", "post", "good", PIN)
        @test a.id == "mastodon:m4s@fosstodon.org" && a.server == "https://fosstodon.org"
        CM.add_account_with_pin!(app, "mastodon", "Makie", "makie@fosstodon.org", "", "post", "good", PIN)
        CM.add_account_with_pin!(app, "mastodon", "", "sim@julialang.social", "", "amplify", "good", PIN)
        CM.add_account_with_pin!(app, "mastodon", "Bonito", "bonito@fosstodon.org", "", "post", "good", PIN)
        @test_throws BT.AppError CM.add_account_with_pin!(app, "mastodon", "", "x@y.org", "", "post", "good", PIN)   # posts for a brand
        @test_throws BT.AppError CM.add_account_with_pin!(app, "linkedin", "Makie", "simon", "", "post", "good", PIN) # posted by hand
        @test CM.with_vault!(() -> CM.secret(app, a), app, PIN) == "good"
        @test !occursin("good", read(app.file, String))
        @test filemode(app.secrets_file) & 0o777 == 0o600
        @test !occursin("good", read(app.secrets_file, String)) && !CM.vault_active(app)
        @test_throws BT.AppError CM.with_vault!(() -> CM.secret(app, a), app, "wrong pin")
    end

    @testset "publishing: the original, the reposts, the project moves on" begin
        @test_throws BT.AppError CM.publish_draft!(app, 1)                 # not approved
        @test_throws BT.AppError CM.publish_draft!(app, 2)                 # links to a video not set yet
        CM.set_link!(app, p.id, "youtube", "https://youtu.be/bh")
        @test_throws BT.AppError CM.publish_with_pin!(app, 2, "wrong pin")
        @test CM.find_draft(app, 2).status == "approved"                 # a bad PIN never changes a release
        CM.publish_with_pin!(app, 2, PIN)
        @test_throws BT.AppError CM.publish_with_pin!(app, 2, PIN)
        d2 = CM.find_draft(app, 2)
        @test d2.status == "published"
        @test NET.posted == [("mastodon:m4s@fosstodon.org", "A black hole, rendered with Makie: https://youtu.be/bh #julialang")]
        # the Makie account (a brand of the project) and the personal one repost; Bonito's doesn't
        @test Set(first.(NET.reposted)) == Set(["mastodon:makie@fosstodon.org", "mastodon:sim@julialang.social"])
        @test [x.kind for x in d2.posts] == ["original", "repost", "repost"]
        @test CM.find_project(app, p.id).state == "publishing"
        @test_throws BT.AppError CM.edit_draft_text!(app, 2, "changed")    # out is out
        # posted by hand: the link, and the project moves on once everything is out
        CM.review_draft!(app, 1, "approved")
        CM.mark_published!(app, 1, "https://youtu.be/bh")
        @test CM.find_draft(app, 1).posts[1].url == "https://youtu.be/bh"
        @test CM.find_project(app, p.id).state == "community"

        # A release-wide send validates every target, then sends each approved
        # automatic post during one explicit PIN lease.
        d3 = CM.save_draft!(app, p.id; brand = "Makie4Science", platform = "mastodon", kind = "post",
                             title = "", text = "A second release post", media = String[])
        CM.review_draft!(app, d3.id, "approved")
        sent = CM.publish_approved_with_pin!(app, p.id, PIN)
        @test length(sent) == 1 && only(sent).status == "published"
        @test CM.find_draft(app, d3.id).status == "published"
    end

    @testset "replies: checked, answered, not our own" begin
        push!(NET.replies, (ref = "301", cid = "", author = "fan@mastodon.social", author_name = "A Fan",
                            text = "How long did it render?", url = "https://mastodon.social/@fan/301", created = now(UTC)),
                           (ref = "302", cid = "", author = "makie@fosstodon.org", author_name = "Makie",
                            text = "Thanks!", url = "https://fosstodon.org/@makie/302", created = now(UTC)))
        CM.with_vault!(() -> CM.poll_replies!(app), app, PIN)
        rs = CM.project_replies(app.state[], p.id)
        @test CM.find_draft(app, 2).posts[1].stats == Dict("likes" => 12, "reposts" => 3, "replies" => 1)
        @test length(CM.find_draft(app, 2).posts) == 3                     # the reposts kept
        @test CM.stats_total(CM.project_drafts(app.state[], p.id))["likes"] == 24
        @test [r.ref for r in rs] == ["301"] && rs[1].status == "new" && rs[1].account == "mastodon:m4s@fosstodon.org"
        CM.with_vault!(() -> CM.poll_replies!(app), app, PIN)              # not due again yet, and nothing twice
        @test length(app.state[].replies) == 1
        @test occursin("How long did it render?", call(server, chat, "project_replies"))
        @test occursin("Drafted", call(server, chat, "project_answer"; ref = "301", text = "About 2 hours on one GPU."))
        CM.send_answer_with_pin!(app, "301", PIN)
        @test NET.answered == [("mastodon:m4s@fosstodon.org", "301", "About 2 hours on one GPU.")]
        @test CM.find_reply(app, "301").status == "answered"
        @test occursin("No open replies", call(server, chat, "project_replies"))
        @test CM.check_interval(now(UTC) - Hour(2)) == Minute(5)
        @test CM.check_interval(now(UTC) - Day(3)) == Hour(1)
        @test CM.check_interval(now(UTC) - Day(40)) === nothing
    end

    @testset "inbox: mentions that belong to no project, forum topics" begin
        mention(post, author, text; parent = "", age = Hour(1)) =
            (post = post, post_cid = "", root = "", root_cid = "", parent, author, author_name = author,
             text, url = "https://fosstodon.org/@x/$post", created = now(UTC) - age)
        append!(NET.mentions, [mention("401", "student@uni.social", "@makie how do I make a 3D histogram?"),
                               mention("402", "fan@mastodon.social", "@makie congrats!"; parent = "101"),   # a project's reply
                               mention("403", "sim@julialang.social", "@makie see this"),                  # ours
                               mention("404", "old@x.org", "@makie hi"; age = Day(9))])                    # too old
        @test isempty(CM.with_vault!(() -> CM.poll_inbox!(app), app, PIN))
        inbox = app.state[].inbox
        @test [x.ref for x in inbox] == ["mastodon:401"]
        @test inbox[1].account == "mastodon:makie@fosstodon.org" && inbox[1].brand == "Makie" && inbox[1].kind == "mention"
        CM.with_vault!(() -> CM.poll_inbox!(app), app, PIN)                # not due again: nothing twice
        @test length(app.state[].inbox) == 1
        overview = server.projects[]["c1"]
        @test occursin("3D histogram", call(server, overview, "cm_inbox"))
        @test occursin("Drafted", call(server, overview, "cm_answer"; ref = "mastodon:401",
                                       text = "`hist3d` isn't built in, but `barplot` with 3D bars does it."))
        CM.send_item_with_pin!(app, "mastodon:401", PIN)
        @test NET.answered[end] == ("mastodon:makie@fosstodon.org", "401", "`hist3d` isn't built in, but `barplot` with 3D bars does it.")
        @test CM.find_item(app, "mastodon:401").status == "answered"
        @test occursin("Nothing open", call(server, overview, "cm_inbox"))

        # a Discourse tag page, as its JSON comes
        page = Dict("users" => [Dict("id" => 7, "username" => "jdoe", "name" => "Jane Doe")],
                    "topic_list" => Dict("topics" => [
                        Dict("id" => 1, "title" => "About the makie tag", "slug" => "about", "posts_count" => 1,
                             "created_at" => "2020-01-01T00:00:00.000Z", "pinned" => true, "posters" => []),
                        Dict("id" => 9001, "title" => "Colorbar ticks in log scale?", "slug" => "colorbar-ticks",
                             "posts_count" => 1, "created_at" => "2026-10-26T09:12:44.123Z",
                             "posters" => [Dict("user_id" => 7)])]))
        topics = CM.discourse_topics(page, CM.Watch("discourse", "Makie", "https://discourse.julialang.org/tag/makie"))
        @test length(topics) == 1
        @test topics[1].url == "https://discourse.julialang.org/t/colorbar-ticks/9001"
        @test topics[1].author_name == "Jane Doe" && topics[1].text == "No answer yet."
        @test topics[1].created == DateTime(2026, 10, 26, 9, 12, 44)
    end

    @testset "releases start blog post projects; links in drafts" begin
        page = [Dict("tag_name" => "v0.25.0", "name" => "v0.25.0", "draft" => false, "prerelease" => false,
                     "html_url" => "https://github.com/MakieOrg/Makie.jl/releases/tag/v0.25.0", "author" => Dict("login" => "SimonDanisch"),
                     "body" => "## Highlights\n- New `Axis` layout", "published_at" => "2026-10-26T12:00:00Z", "created_at" => "2026-10-26T11:00:00Z"),
                Dict("tag_name" => "v0.26.0-rc1", "name" => nothing, "draft" => false, "prerelease" => true,
                     "html_url" => "x", "author" => Dict("login" => "x"), "body" => nothing,
                     "published_at" => "2026-10-27T12:00:00Z", "created_at" => "2026-10-27T12:00:00Z")]
        w = CM.Watch("github", "Makie", "https://github.com/MakieOrg/Makie.jl")
        rs = CM.github_releases(page, w)
        @test length(rs) == 1 && rs[1].title == "Makie v0.25.0" && rs[1].tag == "v0.25.0"
        @test CM.github_repo("https://github.com/SimonDanisch/Bonito.jl.git") == "SimonDanisch/Bonito.jl"
        x = CM.InboxItem("github:MakieOrg/Makie.jl:v0.25.0", "github", "release", "", "Makie", "SimonDanisch", "SimonDanisch",
                         rs[1].title, rs[1].text, rs[1].url, rs[1].created, "new", "", rs[1].tag, "", "", "")
        CM.add_inbox!(app, [x])
        q = CM.project_from_release!(app, x.ref)
        @test q.title == "Makie v0.25.0 release" && q.brands == ["Makie"] && occursin("post.md", q.brief)
        @test CM.find_item(app, x.ref).status == "done"
        @test CM.missing_links("New post: {blog_url} and video {youtube_url}", q) == ["youtube", "blog"]
        CM.set_link!(app, q.id, "blog", "https://makie.org/website/blogposts/v0.25/")
        @test_throws BT.AppError CM.fill_links("{blog_url} {youtube_url}", CM.find_project(app, q.id))
        @test CM.fill_links("Read it: {blog_url}", CM.find_project(app, q.id)) == "Read it: https://makie.org/website/blogposts/v0.25/"
        @test CM.fill_known_links("no links here", q) == "no links here"
        @test_throws BT.AppError CM.set_link!(app, q.id, "blog", "makie.org")          # https only
    end

    @testset "YouTube: login pieces, comments, the chunked upload" begin
        # RFC 7636, appendix B
        @test CM.pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        v = CM.pkce_verifier()
        @test length(v) == 64 && all(in(CM.URLSAFE), v)
        url = CM.consent_url("123.apps.googleusercontent.com", "http://127.0.0.1:5555", "ch", "st")
        q = HTTP.queryparams(HTTP.URI(url))
        @test q["redirect_uri"] == "http://127.0.0.1:5555" && q["access_type"] == "offline" &&
              q["code_challenge_method"] == "S256" && occursin("youtube.upload", q["scope"])
        @test_throws BT.AppError CM.set_google_client_with_pin!(app, "not-a-client", "x", PIN)
        @test_throws BT.AppError CM.begin_youtube_login!(app, "Makie4Science", "https://example.org/community-youtube-callback", PIN)          # no client yet
        CM.set_google_client_with_pin!(app, "123.apps.googleusercontent.com", "shh", PIN)
        @test CM.with_vault!(() -> CM.google_client(app), app, PIN) == ("123.apps.googleusercontent.com", "shh")
        @test_throws BT.AppError CM.begin_youtube_login!(app, "Bonito", "https://example.org/community-youtube-callback", PIN) # Bonito isn't on YouTube
        redirect = "https://community.example/community-youtube-callback"
        state, auth = CM.begin_youtube_login!(app, "Makie4Science", redirect, PIN)
        @test HTTP.queryparams(HTTP.URI(auth))["redirect_uri"] == redirect
        @test !CM.vault_active(app) && isempty(app.sessions)
        @test CM.youtube_callback!(app, HTTP.Request("GET", CM.YOUTUBE_CALLBACK * "?state=wrong&code=x")).status == 400
        @test CM.youtube_callback!(app, HTTP.Request("GET", CM.YOUTUBE_CALLBACK * "?state=$state&code=authcode")).status == 200
        @test CM.youtube_callback!(app, HTTP.Request("GET", CM.YOUTUBE_CALLBACK * "?state=$state&code=replay")).status == 400
        @test_throws BT.AppError CM.complete_youtube_login!(app, state, "wrong pin")
        @test haskey(app.youtube_logins, state)
        port = CM.free_port()
        fake = HTTP.serve!("127.0.0.1", port) do req
            if startswith(req.target, "/token")
                fields = HTTP.queryparams(HTTP.URI("http://x/?" * String(copy(req.body))))
                @test fields["code"] == "authcode" && fields["client_secret"] == "shh"
                @test CM.pkce_challenge(fields["code_verifier"]) == HTTP.queryparams(HTTP.URI(auth))["code_challenge"]
                return HTTP.Response(200, JSON.json(Dict("access_token"=>"private-access", "refresh_token"=>"private-refresh")))
            end
            @test HTTP.header(req, "Authorization") == "Bearer private-access"
            HTTP.Response(200, JSON.json(Dict("items"=>[Dict("id"=>"test-channel", "snippet"=>Dict("title"=>"Test channel"))])))
        end
        try
            account = CM.complete_youtube_login!(app, state, PIN; token_url="http://127.0.0.1:$port/token", channels_url="http://127.0.0.1:$port/channels")
            @test account.platform == "youtube" && account.brand == "Makie4Science"
            @test CM.with_vault!(() -> CM.secret(app, account), app, PIN) == "private-refresh"
            @test !CM.vault_active(app) && isempty(app.sessions)
            @test !occursin("private-refresh", read(app.secrets_file, String))
            @test_throws BT.AppError CM.google_access(app, account)
            @test_throws BT.AppError CM.complete_youtube_login!(app, state, PIN)
        finally
            close(fake)
        end

        page = Dict("items" => [Dict("snippet" => Dict(
            "topLevelComment" => Dict("id" => "c1", "snippet" => Dict("authorDisplayName" => "@astro", "textOriginal" => "Gorgeous!",
                                                                       "publishedAt" => "2026-10-27T10:00:00Z"))),
            "replies" => Dict("comments" => [Dict("id" => "c1.r1", "snippet" => Dict("authorDisplayName" => "@m4s",
                                                  "textOriginal" => "Thanks!", "publishedAt" => "2026-10-27T11:00:00Z"))]))])
        cs = CM.youtube_comments(page, "vid")
        @test [(c.ref, c.cid, c.author) for c in cs] == [("c1", "c1", "@astro"), ("c1.r1", "c1", "@m4s")]
        @test cs[1].url == "https://www.youtube.com/watch?v=vid&lc=c1"

        # a resumable upload session, faked: 308 until the last chunk, then the video
        got = Tuple{String,Vector{UInt8}}[]
        port = CM.free_port()
        server = HTTP.serve!("127.0.0.1", port) do req
            push!(got, (HTTP.header(req, "Content-Range"), copy(req.body)))
            last = endswith(HTTP.header(req, "Content-Range"), "-9/10")
            return last ? HTTP.Response(200, JSON.json(Dict("id" => "vid123"))) : HTTP.Response(308, "")
        end
        file = tempname() * ".mp4"
        write(file, UInt8.(0:9))
        steps = Tuple{Int,Int}[]
        video = CM.upload_resumable("http://127.0.0.1:$port/upload", file, "tok"; chunk = 4,
                                    progress = (s, t) -> push!(steps, (s, t)))
        close(server)
        @test video["id"] == "vid123"
        @test first.(got) == ["bytes 0-3/10", "bytes 4-7/10", "bytes 8-9/10"]
        @test reduce(vcat, last.(got)) == UInt8.(0:9)
        @test steps == [(4, 10), (8, 10)]
        @test CM.hashtags("New video #JuliaLang #Makie and #JuliaLang again") == ["JuliaLang", "Makie"]
    end

    @testset "Facebook and Instagram: multipart, the chunked upload, the streamed upload" begin
        body, ct = CM.multipart(["a" => "1", "upload_phase" => "start"], "video_file_chunk" => UInt8[0x00, 0xff, 0x0d, 0x0a])
        boundary = split(ct, "boundary=")[2]
        s = String(copy(body))
        @test startswith(ct, "multipart/form-data") && occursin("--$boundary\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n", s)
        @test endswith(s, "--$boundary--\r\n")
        i = findfirst(Vector{UInt8}("filename=\"chunk\""), body)
        @test body[findnext(Vector{UInt8}("\r\n\r\n"), body, last(i))[end]+1:end][1:4] == UInt8[0x00, 0xff, 0x0d, 0x0a]

        # Graph's chunked video upload, faked: hands out the byte ranges, keeps what it gets
        got = UInt8[]
        phases = String[]
        ranges = [(0, 4), (4, 8), (8, 10), (10, 10)]
        port = CM.free_port()
        server = HTTP.serve!("127.0.0.1", port) do req
            b = copy(req.body)                    # the request's bytes (HTTP's server hands a BytesBody)
            phase = match(r"name=\"upload_phase\"\r\n\r\n(\w+)", String(copy(b))).captures[1]
            push!(phases, phase)
            phase == "start" && return HTTP.Response(200, JSON.json(Dict("upload_session_id" => "s1", "video_id" => "v1",
                                                                          "start_offset" => "0", "end_offset" => "4")))
            phase == "finish" && return HTTP.Response(200, JSON.json(Dict("success" => true)))
            m = findfirst(Vector{UInt8}("filename=\"chunk\""), b)
            from = findnext(Vector{UInt8}("\r\n\r\n"), b, last(m))[end] + 1
            to = findlast(Vector{UInt8}("\r\n--"), b)[1] - 1
            append!(got, b[from:to])
            n = count(==("transfer"), phases)
            return HTTP.Response(200, JSON.json(Dict("start_offset" => string(ranges[n+1][1]), "end_offset" => string(ranges[n+1][2]))))
        end
        file = tempname() * ".mp4"
        write(file, UInt8.(10:19))
        @test CM.facebook_video("http://127.0.0.1:$port/videos", "tok", file, "T", "D") == "v1"
        close(server)
        @test phases == ["start", "transfer", "transfer", "transfer", "finish"]
        @test got == UInt8.(10:19)

        # Instagram's upload: the whole file, streamed, with its size and offset
        seen = Ref{Any}(nothing)
        port = CM.free_port()
        server = HTTP.serve!("127.0.0.1", port) do req
            seen[] = (HTTP.header(req, "Authorization"), HTTP.header(req, "file_size"), HTTP.header(req, "offset"), copy(req.body))
            return HTTP.Response(200, JSON.json(Dict("success" => true)))
        end
        CM.rupload("http://127.0.0.1:$port/c1", "tok", file)
        close(server)
        @test seen[][1:3] == ("OAuth tok", "10", "0") && seen[][4] == UInt8.(10:19)
        @test_throws BT.AppError CM.verify_account(CM.Facebook(), app.state[].accounts[1], "x")
    end

    @testset "state survives a restart" begin
        again = CommunityApp(app.ctx; poll = false)
        for f in (:projects, :drafts, :accounts, :replies, :inbox)
            @test all(splat(same), zip(getfield(again.state[], f), getfield(app.state[], f)))
        end
        @test again.state[].next_draft == 4
        @test !CM.vault_active(again)
        @test_throws BT.AppError CM.secret(again, CM.find_account(again, "mastodon:m4s@fosstodon.org"))
    end
end
