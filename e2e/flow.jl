# A walk through the Community app in a real browser (BonitoAgents' test kit: a
# dev server, an Electron window, a scripted mock agent), with screenshots:
#
#     julia --project=e2e e2e/flow.jl        # → e2e/shots/*.png
#
# Brands are picked and "Start drafting" is clicked in the overview; the
# overview's agent starts the project chat (`cm_start_project_chat`), whose
# agent writes the drafts (`project_draft`) and submits them, all through the
# real MCP. Then the project's pane is reviewed, a draft approved, one sent back.
using BonitoAgents, BonitoCommunity, Dates, Test
const BT = BonitoAgents
const CM = BonitoCommunity
include(joinpath(pkgdir(BonitoAgents), "test", "testkit", "TestKit.jl"))
const TK = TestKit

const SHOTS = joinpath(@__DIR__, "shots")
mkpath(SHOTS)
const P = "2026-10-black-hole-render"
const VIDEO = "/home/sim/Programmieren/Science4Makie/black-hole-complete-20261025.mp4"

const DRAFTS = [
    (brand = "Makie4Science", platform = "youtube", kind = "video", media = "black-hole.mp4",
     title = "Rendering a Black Hole with Makie: Ray-Traced Gravitational Lensing",
     text = "We trace light around a Schwarzschild black hole and render the accretion disk with Makie.\n\n" *
            "0:00 Why black holes bend light\n0:42 Tracing geodesics\n2:10 The accretion disk\n3:35 Rendering with Makie\n\n" *
            "Code: https://github.com/MakieOrg\n#julialang #makie #science"),
    (brand = "Makie4Science", platform = "tiktok", kind = "video", media = "black-hole.mp4", title = "",
     text = "This is what a black hole really looks like: real physics, rendered with Makie 🕳️ #science #physics #julialang"),
    (brand = "Makie4Science", platform = "instagram", kind = "reel", media = "black-hole.mp4", title = "",
     text = "Light bending around a black hole, ray traced and rendered in Makie. Not an artist's impression: real geodesics. 🌌\n#blackhole #astrophysics #dataviz"),
    (brand = "Makie4Science", platform = "facebook", kind = "video", media = "black-hole.mp4", title = "",
     text = "How do you render a black hole? We traced light rays through curved spacetime and rendered the result with Makie, the Julia plotting library. Full walkthrough on YouTube."),
    (brand = "Makie4Science", platform = "bluesky", kind = "post", media = "", title = "",
     text = "We ray traced a black hole in Julia: geodesics, accretion disk, gravitational lensing, all rendered with Makie. Full video 👇 {youtube_url} #julialang"),
    (brand = "Makie4Science", platform = "mastodon", kind = "post", media = "", title = "",
     text = "New Makie4Science video: ray tracing a black hole in Julia, from geodesics to the final Makie render.\n\n{youtube_url}\n\n#JuliaLang #Makie #Astrophysics #DataViz"),
    (brand = "Makie", platform = "linkedin", kind = "post", media = "", title = "",
     text = "Scientific visualization is where Makie shines brightest. In our new Makie4Science video we ray trace a black hole and render it with Makie.\n---\nFull video: {youtube_url}"),
]

project_draft(i, d) = TK.mcp_call("project_draft"; real_process = true, id = "d$i", brand = d.brand, platform = d.platform,
                                  kind = d.kind, title = d.title, text = d.text, media = d.media)

agent(prompt) =
    occursin("Start drafting project", prompt) ?
        [TK.mcp_call("cm_start_project_chat"; real_process = true, id = "start", project = P,
                     prompt = "DRAFT-THE-POSTS: the black hole render in this folder, for Makie4Science (Makie reposts)."),
         TK.text("Started the project's chat; it is drafting the posts."), TK.end_turn()] :
    occursin("DRAFT-THE-POSTS", prompt) ?
        [[project_draft(i, d) for (i, d) in enumerate(DRAFTS)]...,
         TK.mcp_call("project_submit"; real_process = true, id = "submit",
                     message = "Seven drafts: the YouTube upload, TikTok, a Reel, Facebook, Bluesky and Mastodon link posts, LinkedIn."),
         TK.text("Seven drafts are ready for review in the pane: YouTube, TikTok, Instagram, Facebook, " *
                 "Bluesky and Mastodon (both link to the YouTube video), and LinkedIn for Makie."), TK.end_turn()] :
    occursin("Please revise draft", prompt) ?
        [TK.text("I'll rewrite it."), TK.end_turn()] :
        [TK.text("ok"), TK.end_turn()]

# The app's state and its projects in a folder of their own.
dir = mktempdir()
projects = joinpath(dir, "projects")
mkpath(joinpath(projects, P))
symlink(VIDEO, joinpath(projects, P, "black-hole.mp4"))
write(joinpath(projects, P, "notes.md"), "Render notes: 4k, 120 s, one GPU.\n")
mkpath(joinpath(projects, "2026-11-makie-0-25-release"))
mkpath(joinpath(dir, "state", "apps", "community"))
BT.atomic_write_json(joinpath(dir, "state", "apps", "community", "settings.json"),
                     CM.Settings(projects, CM.DEFAULT_BRANDS, CM.Watch[], "private"))

shot(s, name) = (sleep(1.0); TK.screenshot(s, joinpath(SHOTS, name * ".png")))
js(s, code) = TK.eval_js(s, code)

s = TK.dev_server(; agent, dir, apps = (BT.BUILTIN_APPS..., CommunityApp), browser_width = 1600, browser_height = 1000)
try
    app = s.h.state.apps["community"]
    for _ in 1:240
        any(isopen, values(s.h.state.workers[])) && break
        sleep(0.5)
    end
    worker = only(values(s.h.state.workers[]))
    overview = BT.ensure_app_chat!(s.h.state, app; worker_id = worker.worker_id)
    # an account, so the Accounts panel and the publish button have something to show
    CM.update!(st -> CM.with(st; accounts = [CM.Account("mastodon:m4s@fosstodon.org", "mastodon", "Makie4Science",
        "m4s@fosstodon.org", "https://fosstodon.org", "post")]), app)

    # an inbox: a question by mention, a forum topic
    CM.update!(st -> CM.with(st; inbox = [
        CM.InboxItem("mastodon:501", "mastodon", "mention", "mastodon:m4s@fosstodon.org", "Makie4Science", "phd@uni.social",
                     "A PhD Student", "", "@m4s@fosstodon.org could you do a video on volume rendering of CT scans?",
                     "https://uni.social/@phd/501", now(UTC) - Hour(3), "new", "", "501", "", "", ""),
        CM.InboxItem("discourse:discourse.julialang.org:9001", "discourse", "topic", "", "Makie", "jdoe", "Jane Doe",
                     "Colorbar ticks in log scale?", "No answer yet.", "https://discourse.julialang.org/t/colorbar-ticks/9001",
                     now(UTC) - Hour(5), "new", "", "9001", "", "", ""),
        CM.InboxItem("github:MakieOrg/Makie.jl:v0.25.0", "github", "release", "", "Makie", "SimonDanisch", "SimonDanisch",
                     "Makie v0.25.0", "## Highlights\n- A new layout engine\n- Faster text rendering",
                     "https://github.com/MakieOrg/Makie.jl/releases/tag/v0.25.0", now(UTC) - Hour(8), "new", "", "v0.25.0", "", "", "")]), app)

    TK.open_browser(s)
    TK.open_chat(s, overview.id)
    TK.wait_for(s, "the overview", "!!document.querySelector('.cm-grid .cm-project')"; timeout = 30)
    shot(s, "1-overview-new")

    # Exercise first-use PIN setup through the real dashboard, including the
    # modal's visible inputs and its submit action.
    js(s, "document.querySelector('[data-act=toggle-accounts]').click(); true")
    TK.wait_for(s, "the initial account setup", "!!document.querySelector('[data-act=set-pin]')"; timeout = 10)
    js(s, "document.querySelector('[data-act=set-pin]').click(); true")
    TK.wait_for(s, "the PIN dialog inputs", "document.querySelectorAll('.cm-pin-dialog .bw-modal-open input').length === 2"; timeout = 10)
    @test js(s, "document.querySelector('.cm-pin-dialog input').getBoundingClientRect().height > 0")
    shot(s, "1b-set-pin")
    # Dismiss through the shared modal, then reopen with a fresh, empty body.
    js(s, "document.querySelector('.cm-pin-dialog .bw-modal-close').click(); true")
    TK.wait_for(s, "the PIN modal closed", "!document.querySelector('.cm-pin-dialog .bw-modal-open')"; timeout = 10)
    js(s, "document.querySelector('[data-act=set-pin]').click(); true")
    TK.wait_for(s, "the PIN modal reopened", "!!document.querySelector('.cm-pin-dialog .bw-modal-open input')"; timeout = 10)
    @test js(s, "document.querySelector('.cm-pin-dialog input').value") == ""
    js(s, "document.querySelector('.cm-pin-dialog input').dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true})); true")
    TK.wait_for(s, "Escape dismisses the PIN modal", "!document.querySelector('.cm-pin-dialog .bw-modal-open')"; timeout = 10)
    js(s, "document.querySelector('[data-act=set-pin]').click(); true")
    TK.wait_for(s, "the PIN modal for backdrop dismissal", "!!document.querySelector('.cm-pin-dialog .bw-modal-open input')"; timeout = 10)
    js(s, "(() => { const b = document.querySelector('.cm-pin-dialog .bw-modal-overlay'); b.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true})); b.click(); return true; })()")
    TK.wait_for(s, "the backdrop dismisses the PIN modal", "!document.querySelector('.cm-pin-dialog .bw-modal-open')"; timeout = 10)
    js(s, "document.querySelector('[data-act=set-pin]').click(); true")
    TK.wait_for(s, "the PIN modal for submission", "!!document.querySelector('.cm-pin-dialog .bw-modal-open input')"; timeout = 10)
    js(s, "(() => { const p = document.querySelector('.cm-pin-dialog'); p.querySelectorAll('input').forEach(i => i.value = 'e2e-only PIN'); p.querySelector('[data-act=pin-submit]').click(); return true; })()")
    TK.wait_for(s, "the account cards after setting PIN", "!!document.querySelector('.cm-platform-grid')"; timeout = 10)
    @test CM.vault_exists(app)
    @test js(s, "getComputedStyle(document.querySelector('[data-act=create], [data-act=toggle-new]')).borderRadius !== '0px'")
    # Server theme variables control both plugin surfaces and shared buttons.
    js(s, "document.documentElement.style.setProperty('--bw-accent', '#8b5cf6'); document.documentElement.style.setProperty('--bw-bg-panel', '#fef3c7'); true")
    TK.wait_for(s, "the shared button theme transition", "getComputedStyle(document.querySelector('[data-act=toggle-new]')).backgroundColor === 'rgb(139, 92, 246)'"; timeout = 5)
    @test js(s, "getComputedStyle(document.querySelector('[data-act=toggle-new]')).backgroundColor") == "rgb(139, 92, 246)"
    @test js(s, "getComputedStyle(document.querySelector('.cm-platform-card')).backgroundColor") == "rgb(254, 243, 199)"
    js(s, "document.documentElement.style.removeProperty('--bw-accent'); document.documentElement.style.removeProperty('--bw-bg-panel'); true")
    js(s, "document.querySelector('[data-act=toggle-accounts]').click(); true")

    # pick the brands on the black hole card, then start drafting
    card = "[...document.querySelectorAll('.cm-project')].find(c => c.innerText.includes('Black hole'))"
    @test occursin("Black hole render", js(s, "$card.querySelector('.cm-project-title').textContent"))
    @test !occursin("null", js(s, "document.querySelector('.cm-grid').innerText"))
    js(s, "$card.querySelector('[data-value=\"Makie4Science\"]').click(); true")
    js(s, "$card.querySelector('[data-value=\"Makie\"]').click(); true")
    TK.wait_for(s, "the start button enabled", "!$card.querySelector('[data-act=start]').disabled"; timeout = 10)
    js(s, "$card.querySelector('[data-act=start]').click(); true")
    TK.wait_for(s, "the project chat started", "!!$card?.dataset.chat"; timeout = 60)
    p = CM.find_project(app, P)
    for _ in 1:120
        CM.find_project(app, P).state == "review" && break
        sleep(0.5)
    end
    @test CM.find_project(app, P).state == "review"
    @test length(CM.project_drafts(app.state[], P)) == length(DRAFTS)
    shot(s, "2-overview-drafted")

    # the accounts panel
    @test occursin("Colorbar ticks", js(s, "document.querySelector('.cm-replies').innerText"))
    # a release starts a blog post project
    js(s, "document.querySelector('[data-act=inbox_project]').click(); true")
    TK.wait_for(s, "the release's project", "[...document.querySelectorAll('.cm-project-title')].some(t => t.textContent === 'Makie v0.25.0 release')"; timeout = 10)
    shot(s, "2b-release-project")
    js(s, "document.querySelector('[data-act=toggle-accounts]').click(); true")
    shot(s, "3-accounts")
    js(s, "document.querySelector('.cm-platform-grid').scrollIntoView(); true")
    shot(s, "3b-accounts-youtube-meta")
    js(s, "document.querySelector('[data-act=toggle-accounts]').click(); true")

    # the project's own pane
    TK.open_chat(s, CM.find_project(app, P).chat)
    TK.wait_for(s, "the project pane", "!!document.querySelector('.cm-drafts .cm-draft')"; timeout = 30)
    shot(s, "4-project")
    @test js(s, "document.querySelectorAll('[data-save^=\"link:\"]').length") == 2
    @test js(s, "document.querySelectorAll('.cm-link-chip').length") >= 3
    js(s, "document.querySelector('.cm-drafts').scrollIntoView(); true")
    shot(s, "5-drafts")
    # Stable item/region identities: reviewing one card must preserve the
    # material player and another card, including unsaved browser input.
    js(s, "document.querySelector('.cm-player video').dataset.preserve = 'player'; document.querySelectorAll('.cm-drafts .cm-draft')[2].dataset.preserve = 'card'; true")

    # approve the YouTube draft, send the TikTok one back with a note
    yt = CM.project_drafts(app.state[], P)[1].id
    tt = CM.project_drafts(app.state[], P)[2].id
    js(s, "document.querySelector('[data-draft=\"$yt\"] [data-act=approve]').click(); true")
    js(s, "document.querySelector('[data-draft=\"$tt\"] [data-act=changes-open]').click(); true")
    TK.wait_for(s, "the note field", "!!document.querySelector('[data-box=\"changes-$tt\"] input')"; timeout = 10)
    js(s, """(() => { const i = document.querySelector('[data-box="changes-$tt"] input');
                     i.value = 'Say it is real physics, not an artist impression'; return true; })()""")
    js(s, "document.querySelector('[data-box=\"changes-$tt\"] [data-act=changes]').click(); true")
    for _ in 1:40
        CM.find_draft(app, tt).status == "changes" && CM.find_draft(app, yt).status == "approved" && break
        sleep(0.25)
    end
    @test CM.find_draft(app, yt).status == "approved"
    @test CM.find_draft(app, tt).status == "changes"
    @test js(s, "document.querySelector('.cm-player video').dataset.preserve") == "player"
    @test js(s, "!!document.querySelector('.cm-drafts .cm-draft[data-preserve=card]')")
    # and the cards say so
    TK.wait_for(s, "the YouTube card approved",
        "document.querySelector('[data-draft=\"$yt\"] .cm-status')?.textContent === 'approved'"; timeout = 10)
    TK.wait_for(s, "the TikTok card sent back",
        "document.querySelector('[data-draft=\"$tt\"] .cm-callout')?.textContent.includes('real physics')"; timeout = 10)
    js(s, "document.querySelector('.cm-drafts').scrollIntoView(); true")
    shot(s, "6-reviewed")

    # published Mastodon post with a reply, to show the replies section
    md = only(filter(d -> d.platform == "mastodon", CM.project_drafts(app.state[], P)))
    CM.set_link!(app, P, "youtube", "https://youtu.be/blackhole")
    CM.set_draft!(app, md.id; status = "published",
                  posts = [CM.Post("mastodon:m4s@fosstodon.org", "original", "1", "", "https://fosstodon.org/@m4s/1", now(UTC),
                                   Dict("likes" => 48, "reposts" => 17, "replies" => 1))])
    CM.update!(st -> CM.with(st; replies = [CM.Reply("9", "", P, md.id, "mastodon", "mastodon:m4s@fosstodon.org",
        "astro@mastodon.social", "Astro Fan", "This is gorgeous! How long did a frame take to render?",
        "https://mastodon.social/@astro/9", now(UTC) - Minute(12), "new", "")]), app)
    TK.wait_for(s, "the reply", "!!document.querySelector('.cm-reply')"; timeout = 10)
    js(s, "document.querySelector('.cm-replies').scrollIntoView(); true")
    shot(s, "7-replies")
    @test occursin("48 likes", js(s, "document.querySelector('[data-draft=\"$(md.id)\"]').innerText"))
    @test isempty(TK.js_errors(s))
finally
    close(s)
end
