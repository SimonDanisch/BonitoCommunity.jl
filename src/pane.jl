# The panes. The app's own chat shows the overview (projects, accounts); a
# project's chat shows that project (material, brief, drafts, replies). Either
# way the dashboard sits left of the chat it belongs to.

function BonitoAgents.chat_pane(app::CommunityApp, view)
    key = chat_key(view)
    project = startswith(key, PROJECT_KEY) ? key[length(PROJECT_KEY)+1:end] : ""
    return (ChatHeader(view),
            DOM.div(Dashboard(app, view, project),
                    DOM.div(ChatNotice(view), ChatTranscript(view), ChatComposer(view), ChatToolbar(); class = "cm-chat");
                    class = "cm-split"))
end

"""
    Dashboard(app, view, project)

The dashboard for one tab: the overview (`project == ""`) or one project. The
browser module (`community.js`) draws it from the data it is sent and sends back
what the user does; `feedback` tells this tab when something it asked for can't
be done.
"""
struct Dashboard{V}
    app::CommunityApp
    view::V
    project::String
end

const CommunityLib = Bonito.ES6Module(joinpath(@__DIR__, "community.js"))

function Bonito.jsrender(session::Bonito.Session, d::Dashboard)
    act = Observable{Any}(nothing)
    feedback = Observable("")
    navigate = Observable("")      # a page to open in a new tab (Google's consent page)
    on(session, act) do a
        a isa AbstractVector && length(a) == 3 && pane_action!(d, (; feedback, navigate), a[1], a[2], a[3])
    end
    data = map((s, notice) -> dashboard_data(d, s, notice), session, d.app.state, d.app.notice)
    root = DOM.div(; class = "cm-dash")
    connect = js"""$(CommunityLib).then(lib => lib.connect($(root), $(data), $(act), $(feedback), $(navigate)))"""
    return Bonito.jsrender(session, DOM.div(CommunityStyles, root, connect; class = "cm-dash-wrap"))
end

# ── what the page is sent ───────────────────────────────────────────────────

const PLATFORM_COLORS = Dict("youtube" => "#ff0033", "tiktok" => "#111111", "instagram" => "#e1306c",
                             "facebook" => "#1877f2", "bluesky" => "#1185fe", "mastodon" => "#6364ff",
                             "linkedin" => "#0a66c2")

function platform_data(pl::Platform)
    Dict{String,Any}("id" => platform_id(pl), "name" => platform_name(pl), "color" => PLATFORM_COLORS[platform_id(pl)],
                     "publishes" => publishes(pl), "max" => max_text(pl))
end

when(t::DateTime) = relative_time_label(datetime2unix(t))

# The text as it will be published, the links filled in that the project has.
shown_text(d::Draft, p::Project) = fill_known_links(d.text, p)

function draft_data(app::CommunityApp, d::Draft, p::Project)
    pl = find_platform(d.platform)
    account = findfirst(a -> a.role == "post" && a.brand == d.brand && a.platform == d.platform, app.state[].accounts)
    Dict{String,Any}(
        "id" => d.id, "brand" => d.brand, "platform" => platform_id(pl), "kind" => d.kind,
        "title" => d.title, "text" => d.text, "final_text" => shown_text(d, p), "media" => d.media,
        "status" => d.status, "note" => d.note, "chars" => text_length(pl, d.text), "max" => max_text(pl),
        "publishes" => publishes(pl), "has_account" => account !== nothing,
        "needs_links" => missing_links(d.text, p),
        "posts" => [Dict("url" => x.url, "kind" => x.kind, "account" => x.account) for x in d.posts],
        "stats" => isempty(d.posts) ? Dict{String,Int}() : d.posts[1].stats,
        "updated" => when(d.updated))
end

function inbox_data(x::InboxItem)
    Dict{String,Any}("ref" => x.ref, "source" => x.source, "kind" => x.kind, "brand" => x.brand, "author" => x.author,
                     "author_name" => x.author_name, "title" => x.title, "text" => x.text, "url" => x.url,
                     "when" => when(x.created), "status" => x.status, "answer" => x.answer)
end

function reply_data(r::Reply)
    Dict{String,Any}("ref" => r.ref, "platform" => r.platform, "author" => r.author, "author_name" => r.author_name,
                     "text" => r.text, "url" => r.url, "when" => when(r.created), "status" => r.status,
                     "answer" => r.answer, "draft" => r.draft)
end

# A file of the project as the page shows it: a URL the browser streams it from.
file_data(d::Dashboard, p::Project, f::AbstractString) =
    Dict{String,Any}("name" => f, "video" => is_video(f), "image" => is_image(f),
                     "url" => chat_file_url(d.view, joinpath(project_folder(projects_dir(d.app), p), f)))

function counts(drafts::Vector{Draft})
    Dict{String,Any}("review" => count(x -> x.status in ("draft", "changes"), drafts),
                     "approved" => count(x -> x.status == "approved", drafts),
                     "published" => count(x -> x.status == "published", drafts),
                     "failed" => count(x -> x.status == "failed", drafts), "total" => length(drafts))
end

function project_card(d::Dashboard, s::CommunityFile, p::Project)
    files = material(projects_dir(d.app), p)
    cover = findfirst(f -> is_video(f) || is_image(f), files)
    Dict{String,Any}(
        "id" => p.id, "title" => p.title, "state" => p.state, "brands" => p.brands, "brief" => p.brief,
        "chat" => isempty(p.chat) || chat_title(d.app.ctx.server, p.chat) === nothing ? nothing : p.chat,
        "cover" => cover === nothing ? nothing : file_data(d, p, files[cover]),
        "nfiles" => length(files), "counts" => counts(project_drafts(s, p.id)),
        "new_replies" => count(r -> r.status == "new", project_replies(s, p.id)),
        "platforms" => unique([x.platform for x in project_drafts(s, p.id)]),
        "stats" => stats_total(project_drafts(s, p.id)),
        "created" => when(p.created))
end

function dashboard_data(d::Dashboard, s::CommunityFile, notice::String)
    app = d.app
    platforms = [platform_data(pl) for pl in PLATFORMS]
    base = Dict{String,Any}(
        "brands" => brand_names(app), "states" => collect(PROJECT_STATES), "notice" => notice,
        "platforms" => platforms, "folder" => projects_dir(app),
        "sources" => vcat(platforms, Dict{String,Any}("id" => "discourse", "name" => "Discourse", "color" => "#9558b2"),
                          Dict{String,Any}("id" => "github", "name" => "GitHub", "color" => "#24292f")))
    if isempty(d.project)
        base["mode"] = "overview"
        base["projects"] = [project_card(d, s, p) for p in reverse(s.projects)]   # newest first
        base["accounts"] = [Dict("id" => a.id, "platform" => a.platform, "brand" => a.brand, "handle" => a.handle,
                                 "server" => a.server, "role" => a.role) for a in s.accounts]
        # the open items first, then what was handled, each newest first
        open = sort(filter(x -> x.status in ("new", "drafted"), s.inbox); by = x -> x.created, rev = true)
        handled = sort(filter(x -> !(x.status in ("new", "drafted")), s.inbox); by = x -> x.created, rev = true)
        base["inbox"] = [inbox_data(x) for x in vcat(open, first(handled, 30))]
        base["watches"] = [w.url for w in app.settings.watches]
        base["google_client"] = !isempty(first(google_client(app)))
        base["youtube_brands"] = [b.name for b in app.settings.brands if "youtube" in b.platforms]
        base["meta_brands"] = [b.name for b in app.settings.brands if "facebook" in b.platforms || "instagram" in b.platforms]
        base["youtube_privacy"] = app.settings.youtube_privacy
        return base
    end
    i = findfirst(p -> p.id == d.project, s.projects)
    if i === nothing
        base["mode"] = "missing"
        base["project_id"] = d.project
        return base
    end
    p = s.projects[i]
    files = material(projects_dir(app), p)
    base["mode"] = "project"
    base["project"] = merge(project_card(d, s, p), Dict{String,Any}(
        "links" => p.links, "files" => [file_data(d, p, f) for f in files],
        "drafts" => [draft_data(app, x, p) for x in project_drafts(s, p.id)],
        "replies" => [reply_data(r) for r in sort(project_replies(s, p.id); by = r -> r.created, rev = true)]))
    return base
end

# ── what the page sends ─────────────────────────────────────────────────────

const PANE_ACTIONS = ("new", "rescan", "start", "open", "overview", "add_account", "remove_account",
                      "title", "brands", "brief", "link", "state", "approve", "approve_all", "unapprove", "changes",
                      "edit", "remove", "publish", "mark", "retry", "answer", "ask_answer", "ask_answers",
                      "send", "ignore", "inbox_answer", "inbox_send", "inbox_done", "inbox_ignore", "inbox_reopen",
                      "inbox_ask", "inbox_ask_all", "inbox_project", "google_client", "connect_youtube", "add_meta")

# A click on the dashboard. What can't be done (an account whose password is
# wrong, a draft another tab just removed) is said in this tab, not more.
function pane_action!(d::Dashboard, tab::NamedTuple, action::AbstractString, id, value)
    action in PANE_ACTIONS || return @info "community action not understood" action
    try
        r = pane_action!(d, Val(Symbol(action)), id, value)
        r isa OpenPage && (tab.navigate[] = r.url)
    catch e
        e isa AppError || rethrow()
        tab.feedback[] = e.msg
    end
    return nothing
end

"What an action answers when the tab should open a page."
struct OpenPage
    url::String
end

pane_action!(d::Dashboard, ::Val{:new}, ::Nothing, v::AbstractDict) = new_project!(d.app, v["title"], v["brands"], v["brief"])
pane_action!(d::Dashboard, ::Val{:rescan}, ::Nothing, ::Nothing) = scan_projects!(d.app)
pane_action!(d::Dashboard, ::Val{:open}, chat_id::AbstractString, ::Nothing) = show_chat!(d.view, chat_id)

function pane_action!(d::Dashboard, ::Val{:overview}, ::Nothing, ::Nothing)
    chat = app_chat(d.app.ctx.server, d.app)
    chat === nothing || show_chat!(d.view, chat.id)
    return nothing
end

# Starting a project's chat is the user's own message to the overview's agent:
# it writes the project chat's first prompt from the brief and the material.
function pane_action!(d::Dashboard, ::Val{:start}, id::AbstractString, ::Nothing)
    p = find_project(d.app, id)
    isempty(p.brands) && throw(AppError("pick the project's brands first"))
    send_message!(d.view, "Start drafting project $(p.id) (\"$(p.title)\"): look at it with `cm_projects`, " *
                          "then start its chat with `cm_start_project_chat`.")
    return nothing
end

pane_action!(d::Dashboard, ::Val{:add_account}, ::Nothing, v::AbstractDict) =
    add_account!(d.app, v["platform"], v["brand"], v["handle"], v["server"], v["role"], v["secret"])
pane_action!(d::Dashboard, ::Val{:remove_account}, id::AbstractString, ::Nothing) = remove_account!(d.app, id)
pane_action!(d::Dashboard, ::Val{:google_client}, ::Nothing, v::AbstractDict) =
    set_google_client!(d.app, v["client_id"], v["client_secret"])
pane_action!(d::Dashboard, ::Val{:connect_youtube}, ::Nothing, brand::AbstractString) =
    OpenPage(start_youtube_login!(d.app, brand))
pane_action!(d::Dashboard, ::Val{:add_meta}, ::Nothing, v::AbstractDict) = add_meta_accounts!(d.app, v["brand"], v["token"])

pane_action!(d::Dashboard, ::Val{:brands}, id::AbstractString, brands::AbstractVector) =
    set_project!(d.app, id; brands = isempty(brands) ? String[] : checked_brands(d.app, brands))
pane_action!(d::Dashboard, ::Val{:title}, id::AbstractString, title::AbstractString) = rename_project!(d.app, id, title)
pane_action!(d::Dashboard, ::Val{:brief}, id::AbstractString, brief::AbstractString) =
    set_project!(d.app, id; brief = strip(brief))
function pane_action!(d::Dashboard, ::Val{:link}, id::AbstractString, v::AbstractDict)
    v["key"] in first.(LINK_PLACEHOLDERS) || throw(AppError("unknown link '$(v["key"])'"))
    return set_link!(d.app, id, v["key"], v["url"])
end
pane_action!(d::Dashboard, ::Val{:state}, id::AbstractString, state::AbstractString) = set_project!(d.app, id; state)

pane_action!(d::Dashboard, ::Val{:approve}, id::Integer, ::Nothing) = review_draft!(d.app, Int(id), "approved")
pane_action!(d::Dashboard, ::Val{:unapprove}, id::Integer, ::Nothing) = review_draft!(d.app, Int(id), "draft")
pane_action!(d::Dashboard, ::Val{:retry}, id::Integer, ::Nothing) = review_draft!(d.app, Int(id), "approved")
pane_action!(d::Dashboard, ::Val{:edit}, id::Integer, text::AbstractString) = edit_draft_text!(d.app, Int(id), text)
pane_action!(d::Dashboard, ::Val{:remove}, id::Integer, ::Nothing) = remove_draft!(d.app, Int(id))
pane_action!(d::Dashboard, ::Val{:publish}, id::Integer, ::Nothing) = publish_in_background!(d.app, Int(id))
pane_action!(d::Dashboard, ::Val{:mark}, id::Integer, url::AbstractString) = mark_published!(d.app, Int(id), url)

function pane_action!(d::Dashboard, ::Val{:approve_all}, id::AbstractString, ::Nothing)
    for x in project_drafts(d.app.state[], id)
        x.status == "draft" && review_draft!(d.app, x.id, "approved")
    end
    return nothing
end

# In a project's chat the note also goes to its agent, as the user's message.
function pane_action!(d::Dashboard, ::Val{:changes}, id::Integer, note::AbstractString)
    x = review_draft!(d.app, Int(id), "changes"; note)
    isempty(d.project) || send_message!(d.view, "Please revise draft #$(x.id) ($(x.brand) · $(x.platform)): $(x.note)")
    return nothing
end

pane_action!(d::Dashboard, ::Val{:answer}, ref::AbstractString, text::AbstractString) = draft_answer!(d.app, ref, text)
pane_action!(d::Dashboard, ::Val{:send}, ref::AbstractString, ::Nothing) = send_in_background!(d.app, ref)
pane_action!(d::Dashboard, ::Val{:ignore}, ref::AbstractString, ::Nothing) = set_reply!(d.app, ref; status = "ignored")

function pane_action!(d::Dashboard, ::Val{:ask_answer}, ref::AbstractString, ::Nothing)
    r = find_reply(d.app, ref)
    send_message!(d.view, "Draft an answer to $(r.author_name)'s reply (ref $(r.ref)) with `project_answer`.")
    return nothing
end

function pane_action!(d::Dashboard, ::Val{:ask_answers}, ::Nothing, ::Nothing)
    send_message!(d.view, "Draft answers to the open replies (`project_replies`, then `project_answer`); " *
                          "leave out what needs no answer.")
    return nothing
end

pane_action!(d::Dashboard, ::Val{:inbox_answer}, ref::AbstractString, text::AbstractString) = draft_item_answer!(d.app, ref, text)
pane_action!(d::Dashboard, ::Val{:inbox_project}, ref::AbstractString, ::Nothing) = project_from_release!(d.app, ref)
pane_action!(d::Dashboard, ::Val{:inbox_send}, ref::AbstractString, ::Nothing) = send_item_in_background!(d.app, ref)
pane_action!(d::Dashboard, ::Val{:inbox_done}, ref::AbstractString, ::Nothing) = set_item!(d.app, ref; status = "done")
pane_action!(d::Dashboard, ::Val{:inbox_ignore}, ref::AbstractString, ::Nothing) = set_item!(d.app, ref; status = "ignored")
pane_action!(d::Dashboard, ::Val{:inbox_reopen}, ref::AbstractString, ::Nothing) =
    set_item!(d.app, ref; status = isempty(find_item(d.app, ref).answer) ? "new" : "drafted")

function pane_action!(d::Dashboard, ::Val{:inbox_ask}, ref::AbstractString, ::Nothing)
    x = find_item(d.app, ref)
    send_message!(d.view, "Draft an answer to $(x.author_name)'s $(x.kind == "topic" ? "forum topic" : "mention") " *
                          "(inbox ref $(x.ref)) with `cm_answer`.")
    return nothing
end

function pane_action!(d::Dashboard, ::Val{:inbox_ask_all}, ::Nothing, ::Nothing)
    send_message!(d.view, "Draft answers to the open inbox items (`cm_inbox`, then `cm_answer`); leave out what needs no answer.")
    return nothing
end

pane_action!(::Dashboard, action::Val, id, value) = @info "community action not understood" action id value

# ── styles ──────────────────────────────────────────────────────────────────

const CommunityStyles = Styles(
    CSS(".cm-split", "flex" => "1 1 auto", "min-height" => "0", "display" => "flex"),
    CSS(".cm-dash-wrap", "flex" => "3 1 0", "min-width" => "0", "overflow-y" => "auto",
        "border-right" => "1px solid var(--bt-border)", "background" => "var(--bt-bg)"),
    CSS(".cm-chat", "flex" => "2 1 0", "min-width" => "340px", "max-width" => "640px", "min-height" => "0",
        "display" => "flex", "flex-direction" => "column"),
    CSS("@media (max-width: 1000px)",
        CSS(".cm-split", "flex-direction" => "column"),
        CSS(".cm-dash-wrap", "flex" => "0 1 auto", "max-height" => "60%", "border-right" => "none",
            "border-bottom" => "1px solid var(--bt-border)"),
        CSS(".cm-chat", "max-width" => "none", "min-width" => "0")),

    CSS(".cm-region:empty", "display" => "none"),
    CSS("[data-edit-title][contenteditable='plaintext-only']", "outline" => "none", "border-radius" => "6px",
        "box-shadow" => "0 0 0 2px var(--bt-accent)"),
    CSS(".cm-dash", "padding" => "20px 24px 32px", "display" => "flex", "flex-direction" => "column",
        "gap" => "20px", "max-width" => "1180px", "margin" => "0 auto", "color" => "var(--bt-text)"),
    CSS(".cm-top", "display" => "flex", "align-items" => "center", "gap" => "12px", "flex-wrap" => "wrap"),
    CSS(".cm-h1", "font-size" => "22px", "font-weight" => "650", "margin" => "0", "letter-spacing" => "-0.01em"),
    CSS(".cm-h2", "font-size" => "13px", "font-weight" => "600", "margin" => "0", "text-transform" => "uppercase",
        "letter-spacing" => "0.06em", "color" => "var(--bt-text-muted)"),
    CSS(".cm-sub", "color" => "var(--bt-text-muted)", "font-size" => "var(--bt-text-sm)"),
    CSS(".cm-spacer", "flex" => "1 1 auto"),
    CSS(".cm-row", "display" => "flex", "align-items" => "center", "gap" => "8px", "flex-wrap" => "wrap"),
    CSS(".cm-section", "display" => "flex", "flex-direction" => "column", "gap" => "10px"),
    CSS(".cm-section-head", "display" => "flex", "align-items" => "center", "gap" => "10px"),

    # cards and panels
    CSS(".cm-card", "background" => "var(--bt-surface)", "border" => "1px solid var(--bt-border)",
        "border-radius" => "12px", "box-shadow" => "var(--bt-shadow-sm)"),
    CSS(".cm-panel", "padding" => "16px", "display" => "flex", "flex-direction" => "column", "gap" => "12px"),
    CSS(".cm-notice", "padding" => "10px 14px", "border-radius" => "10px", "font-size" => "var(--bt-text-sm)",
        "background" => "color-mix(in srgb, var(--bt-warning) 14%, transparent)",
        "border" => "1px solid color-mix(in srgb, var(--bt-warning) 45%, transparent)"),
    CSS(".cm-toast", "position" => "sticky", "top" => "0", "z-index" => "5", "padding" => "10px 14px",
        "border-radius" => "10px", "font-size" => "var(--bt-text-sm)", "color" => "#fff",
        "background" => "var(--bt-error)", "box-shadow" => "var(--bt-shadow-md)", "cursor" => "pointer"),

    # project grid
    CSS(".cm-grid", "display" => "grid", "grid-template-columns" => "repeat(auto-fill, minmax(260px, 1fr))", "gap" => "16px"),
    CSS(".cm-project", "overflow" => "hidden", "display" => "flex", "flex-direction" => "column", "cursor" => "pointer",
        "transition" => "transform .12s ease, box-shadow .12s ease, border-color .12s ease"),
    CSS(".cm-project:hover", "transform" => "translateY(-2px)", "box-shadow" => "var(--bt-shadow-md)",
        "border-color" => "var(--bt-border-strong)"),
    CSS(".cm-cover", "aspect-ratio" => "16 / 9", "background" => "linear-gradient(135deg, #e7c626 0%, #e05a7a 50%, #3a7fc4 100%)",
        "position" => "relative", "overflow" => "hidden", "display" => "flex", "align-items" => "center",
        "justify-content" => "center"),
    CSS(".cm-cover video, .cm-cover img", "width" => "100%", "height" => "100%", "object-fit" => "cover", "display" => "block"),
    CSS(".cm-cover-letter", "font-size" => "44px", "font-weight" => "700", "color" => "rgba(255,255,255,.92)",
        "text-shadow" => "0 2px 12px rgba(0,0,0,.25)"),
    CSS(".cm-cover-badge", "position" => "absolute", "top" => "10px", "right" => "10px"),
    CSS(".cm-project-body", "padding" => "12px 14px 14px", "display" => "flex", "flex-direction" => "column", "gap" => "8px"),
    CSS(".cm-project-title", "font-weight" => "600", "font-size" => "15px", "line-height" => "1.3"),
    CSS(".cm-new-card", "border-style" => "dashed", "display" => "flex", "align-items" => "center",
        "justify-content" => "center", "min-height" => "140px", "background" => "transparent", "font" => "inherit", "cursor" => "pointer", "color" => "var(--bt-text-muted)", "font-weight" => "500"),

    # pills, chips, badges
    CSS(".cm-pill", "display" => "inline-flex", "align-items" => "center", "gap" => "5px", "border-radius" => "999px",
        "padding" => "2px 9px", "font-size" => "12px", "font-weight" => "500", "white-space" => "nowrap",
        "background" => "var(--bt-surface-2)", "color" => "var(--bt-text)", "border" => "1px solid var(--bt-border)"),
    CSS(".cm-pill-dot::before", "content" => "''", "display" => "inline-block", "width" => "7px", "height" => "7px", "border-radius" => "50%",
        "background" => "var(--dot, var(--bt-text-faint))"),
    CSS(".cm-brand-toggle", "cursor" => "pointer", "user-select" => "none"),
    CSS(".cm-brand-toggle input", "display" => "none"),
    CSS(".cm-brand-toggle.cm-on", "background" => "color-mix(in srgb, var(--bt-accent) 14%, transparent)",
        "border-color" => "var(--bt-accent)"),
    CSS(".cm-status", "border-radius" => "999px", "padding" => "2px 9px", "font-size" => "11px", "font-weight" => "600",
        "text-transform" => "uppercase", "letter-spacing" => "0.04em", "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-text-muted)"),
    CSS(".cm-status-approved, .cm-status-published, .cm-status-answered",
        "background" => "color-mix(in srgb, var(--bt-success) 16%, transparent)", "color" => "var(--bt-success)"),
    CSS(".cm-status-changes, .cm-status-failed", "background" => "color-mix(in srgb, var(--bt-error) 14%, transparent)",
        "color" => "var(--bt-error)"),
    CSS(".cm-status-publishing, .cm-status-drafted, .cm-status-new",
        "background" => "color-mix(in srgb, var(--bt-accent) 14%, transparent)", "color" => "var(--bt-accent)"),
    CSS(".cm-plat", "display" => "inline-flex", "align-items" => "center", "justify-content" => "center",
        "width" => "26px", "height" => "26px", "border-radius" => "8px", "color" => "#fff", "flex" => "0 0 auto",
        "font-size" => "12px", "font-weight" => "700", "background" => "var(--plat)"),
    CSS(".cm-plat-sm", "width" => "18px", "height" => "18px", "border-radius" => "5px", "font-size" => "10px"),
    CSS(".cm-plats", "display" => "flex", "gap" => "4px"),

    # the state stepper
    CSS(".cm-steps", "display" => "flex", "gap" => "3px", "align-items" => "center"),
    CSS(".cm-step", "height" => "5px", "flex" => "1 1 0", "border-radius" => "3px", "background" => "var(--bt-surface-2)",
        "min-width" => "18px"),
    CSS(".cm-step-done", "background" => "color-mix(in srgb, var(--bt-accent) 45%, var(--bt-surface-2))"),
    CSS(".cm-step-now", "background" => "var(--bt-accent)"),
    CSS(".cm-steps-labeled", "gap" => "6px"),
    CSS(".cm-steps-labeled .cm-step-wrap", "flex" => "1 1 0", "display" => "flex", "flex-direction" => "column", "gap" => "5px"),
    CSS(".cm-step-label", "font-size" => "11px", "color" => "var(--bt-text-faint)", "text-transform" => "capitalize"),
    CSS(".cm-step-label-now", "color" => "var(--bt-text)", "font-weight" => "600"),

    # forms
    CSS(".cm-field", "display" => "flex", "flex-direction" => "column", "gap" => "4px", "font-size" => "var(--bt-text-sm)",
        "color" => "var(--bt-text-muted)"),
    CSS(".cm-input, .cm-textarea, .cm-select", "width" => "100%", "box-sizing" => "border-box", "padding" => "7px 10px",
        "border" => "1px solid var(--bt-border)", "border-radius" => "8px", "background" => "var(--bt-bg)",
        "color" => "var(--bt-text)", "font" => "inherit", "font-size" => "14px"),
    CSS(".cm-input:focus, .cm-textarea:focus, .cm-select:focus", "outline" => "none", "border-color" => "var(--bt-accent)",
        "box-shadow" => "0 0 0 3px color-mix(in srgb, var(--bt-accent) 20%, transparent)"),
    CSS(".cm-textarea", "min-height" => "84px", "resize" => "vertical", "line-height" => "1.45"),
    CSS(".cm-form-grid", "display" => "grid", "grid-template-columns" => "repeat(auto-fill, minmax(180px, 1fr))", "gap" => "10px"),

    # project page
    CSS(".cm-hero", "display" => "grid", "grid-template-columns" => "minmax(0, 1.15fr) minmax(0, 1fr)", "gap" => "16px"),
    CSS("@media (max-width: 1300px)", CSS(".cm-hero", "grid-template-columns" => "minmax(0, 1fr)")),
    CSS(".cm-player", "border-radius" => "10px", "overflow" => "hidden", "background" => "#000"),
    CSS(".cm-player video, .cm-player img", "width" => "100%", "display" => "block", "max-height" => "340px", "object-fit" => "contain"),
    CSS(".cm-files", "display" => "flex", "flex-wrap" => "wrap", "gap" => "6px"),
    CSS(".cm-file", "font-size" => "12px", "padding" => "3px 8px", "border-radius" => "6px", "background" => "var(--bt-surface-2)",
        "max-width" => "100%", "overflow" => "hidden", "text-overflow" => "ellipsis", "white-space" => "nowrap"),
    CSS(".cm-empty", "padding" => "22px", "text-align" => "center", "color" => "var(--bt-text-muted)",
        "font-size" => "var(--bt-text-sm)", "border" => "1px dashed var(--bt-border)", "border-radius" => "10px"),
    CSS(".cm-filters", "display" => "flex", "gap" => "4px"),
    CSS(".cm-filter", "border" => "1px solid transparent", "background" => "none", "color" => "var(--bt-text-muted)",
        "border-radius" => "999px", "padding" => "3px 10px", "font" => "inherit", "font-size" => "13px", "cursor" => "pointer"),
    CSS(".cm-filter-on", "background" => "var(--bt-surface-2)", "color" => "var(--bt-text)", "border-color" => "var(--bt-border)"),

    # draft cards
    CSS(".cm-drafts", "display" => "grid", "grid-template-columns" => "repeat(auto-fill, minmax(300px, 1fr))",
        "gap" => "14px", "align-items" => "start"),
    CSS(".cm-draft", "display" => "flex", "flex-direction" => "column", "overflow" => "hidden",
        "border-top" => "3px solid var(--plat)"),
    CSS(".cm-draft-head", "display" => "flex", "align-items" => "center", "gap" => "10px", "padding" => "12px 14px 0"),
    CSS(".cm-draft-who", "display" => "flex", "flex-direction" => "column", "min-width" => "0", "flex" => "1 1 auto"),
    CSS(".cm-draft-name", "font-weight" => "600", "font-size" => "14px"),
    CSS(".cm-draft-meta", "font-size" => "12px", "color" => "var(--bt-text-muted)"),
    CSS(".cm-draft-body", "padding" => "10px 14px", "display" => "flex", "flex-direction" => "column", "gap" => "8px"),
    CSS(".cm-draft-title", "font-weight" => "600", "font-size" => "15px", "line-height" => "1.35"),
    CSS(".cm-draft-text", "white-space" => "pre-wrap", "overflow-wrap" => "anywhere", "font-size" => "14px",
        "line-height" => "1.5", "outline" => "none", "border-radius" => "6px", "max-height" => "260px", "overflow-y" => "auto"),
    CSS(".cm-draft-text[contenteditable='plaintext-only']", "box-shadow" => "0 0 0 2px var(--bt-accent)", "padding" => "4px",
        "max-height" => "none"),
    CSS(".cm-link-chip", "background" => "color-mix(in srgb, var(--bt-accent) 14%, transparent)", "color" => "var(--bt-accent)",
        "border-radius" => "4px", "padding" => "0 4px", "font-size" => "13px"),
    CSS(".cm-meter", "height" => "3px", "border-radius" => "2px", "background" => "var(--bt-surface-2)", "overflow" => "hidden"),
    CSS(".cm-meter > div", "height" => "100%", "background" => "var(--bt-success)"),
    CSS(".cm-meter-warn > div", "background" => "var(--bt-warning)"),
    CSS(".cm-meter-over > div", "background" => "var(--bt-error)"),
    CSS(".cm-draft-foot", "display" => "flex", "align-items" => "center", "gap" => "6px", "flex-wrap" => "wrap",
        "padding" => "10px 14px 12px", "border-top" => "1px solid var(--bt-border)", "background" => "var(--bt-surface-2)"),
    CSS(".cm-callout", "font-size" => "13px", "padding" => "8px 10px", "border-radius" => "8px",
        "background" => "color-mix(in srgb, var(--bt-error) 10%, transparent)", "color" => "var(--bt-text)",
        "border-left" => "3px solid var(--bt-error)"),
    CSS(".cm-callout-info", "background" => "color-mix(in srgb, var(--bt-warning) 12%, transparent)",
        "border-left-color" => "var(--bt-warning)"),
    CSS(".cm-posted", "font-size" => "13px", "display" => "flex", "flex-direction" => "column", "gap" => "2px"),
    CSS(".cm-posted a", "color" => "var(--bt-accent)", "text-decoration" => "none", "overflow-wrap" => "anywhere"),
    CSS(".cm-stats", "font-size" => "13px", "font-weight" => "600", "color" => "var(--bt-text)", "font-variant-numeric" => "tabular-nums"),

    # replies
    CSS(".cm-replies", "display" => "flex", "flex-direction" => "column", "gap" => "10px"),
    CSS(".cm-reply", "display" => "grid", "grid-template-columns" => "36px minmax(0, 1fr)", "gap" => "10px", "padding" => "12px 14px"),
    CSS(".cm-avatar", "width" => "36px", "height" => "36px", "border-radius" => "50%", "display" => "flex",
        "align-items" => "center", "justify-content" => "center", "color" => "#fff", "font-weight" => "600",
        "background" => "var(--plat)"),
    CSS(".cm-reply-text", "white-space" => "pre-wrap", "overflow-wrap" => "anywhere", "font-size" => "14px", "line-height" => "1.45"),
    CSS(".cm-answer", "border-left" => "2px solid var(--bt-border-strong)", "padding-left" => "10px"),
    CSS(".cm-topic-title", "font-weight" => "600", "font-size" => "15px", "color" => "var(--bt-text)", "text-decoration" => "none"),
    CSS(".cm-topic-title:hover", "color" => "var(--bt-accent)"),
    CSS(".cm-handled", "opacity" => "0.62"),

    # accounts
    CSS(".cm-accounts", "display" => "flex", "flex-direction" => "column", "gap" => "6px"),
    CSS(".cm-account", "display" => "flex", "align-items" => "center", "gap" => "10px", "padding" => "8px 10px",
        "border-radius" => "8px", "background" => "var(--bt-bg)", "border" => "1px solid var(--bt-border)"),
    CSS(".cm-account-handle", "font-weight" => "500", "flex" => "1 1 auto", "min-width" => "0", "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    CSS(".cm-hint", "font-size" => "12px", "color" => "var(--bt-text-muted)", "line-height" => "1.45"),
    CSS(".cm-setup", "display" => "grid", "grid-template-columns" => "repeat(auto-fit, minmax(210px, 1fr))", "gap" => "8px",
        "padding" => "12px", "border-radius" => "10px", "background" => "var(--bt-bg)", "border" => "1px solid var(--bt-border)"),
    CSS(".cm-setup .cm-h2", "grid-column" => "1 / -1", "margin-bottom" => "2px"),
    CSS(".cm-setup-step", "display" => "grid", "gap" => "2px", "font-size" => "12px", "line-height" => "1.4"),
    CSS(".cm-setup-step span", "color" => "var(--bt-text-muted)"),
)
