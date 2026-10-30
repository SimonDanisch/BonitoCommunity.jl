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
    # Explicitly per-tab presentation state; domain state stays on CommunityApp.
    ui::Observable{Dict{String,Any}}
    actions::Observable{Any}
    feedback::Observable{String}
    navigate::Observable{String}
    pin_open::Observable{Bool}
end
Dashboard(app, view, project) = Dashboard(app, view, project,
    Observable(Dict{String,Any}("filter" => "all", "showNew" => false, "showAccounts" => false,
                               "showHandled" => false, "marking" => nothing, "changing" => nothing,
                               "youtube_state" => "", "youtube_url" => "", "showBrands" => false)),
    Observable{Any}(nothing), Observable(""), Observable(""), Observable(false))

function Base.close(d::Dashboard)
    foreach(Bonito.Observables.clear, (d.ui, d.actions, d.feedback, d.navigate, d.pin_open))
end

const CommunityLib = Bonito.ES6Module(joinpath(@__DIR__, "community.js"))

function Bonito.jsrender(session::Bonito.Session, d::Dashboard)
    on(session, d.actions) do a
        d.actions.val = nothing # do not retain submitted PINs or credentials
        a isa AbstractVector && length(a) == 3 || error("invalid Community action message")
        if a[1] == "view"
            all(k -> haskey(d.ui[], k), keys(a[3])) || error("unknown Community view state")
            d.ui[] = merge(d.ui[], Dict{String,Any}(a[3]))
        else
            pane_action!(d, (; feedback = d.feedback, navigate = d.navigate), a[1], a[2], a[3])
        end
    end
    on(session.on_close) do _
        close(d)
    end
    root = dashboard_dom(session, d)
    pin = pin_dialog(d.pin_open)
    connect = js"""$(CommunityLib).then(lib => new lib.DashboardController($(root), $(pin), $(d.pin_open), $(d.actions), $(d.feedback)))"""
    return Bonito.jsrender(session, DOM.div(AppUIStyles, CommunityStyles, root, pin, connect; class = "cm-dash-wrap"))
end

include("views.jl")

# ── what the page is sent ───────────────────────────────────────────────────

const PLATFORM_COLORS = Dict("youtube" => "#ff0033", "tiktok" => "#111111", "instagram" => "#e1306c",
                             "facebook" => "#1877f2", "bluesky" => "#1185fe", "mastodon" => "#6364ff",
                             "linkedin" => "#0a66c2", "discourse" => "#9558b2")

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
function file_data(d::Dashboard, p::Project, f::AbstractString)
    chat = get(d.app.ctx.server.projects[], p.chat, nothing)
    folder = chat === nothing ? project_folder(projects_dir(d.app), p) : chat.worker_path
    return Dict{String,Any}("name" => f, "video" => is_video(f), "image" => is_image(f),
                          "url" => chat_file_url(d.view, joinpath(folder, f)))
end

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
        "brand_details" => [Dict("name"=>b.name, "platforms"=>b.platforms, "notes"=>b.notes, "in_use"=>brand_in_use(app,b.name)) for b in app.settings.brands],
        "platforms" => platforms, "folder" => projects_dir(app),
        "brand_platforms" => Dict(b.name => b.platforms for b in app.settings.brands),
        "sources" => vcat(platforms, Dict{String,Any}("id" => "github", "name" => "GitHub", "color" => "#24292f")))
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
        base["vault_set"] = vault_exists(app)
        base["youtube_url"] = d.ui[]["youtube_url"]
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

const PANE_ACTIONS = ("save_brand", "delete_brand", "new", "rescan", "start", "open", "overview", "add_account", "remove_account",
                      "title", "brands", "brief", "link", "state", "approve", "approve_all", "publish_all", "unapprove", "changes",
                      "edit", "remove", "publish", "mark", "retry", "answer", "ask_answer", "ask_answers",
                      "send", "ignore", "inbox_answer", "inbox_send", "inbox_done", "inbox_ignore", "inbox_reopen",
                      "inbox_ask", "inbox_ask_all", "inbox_project", "set_pin", "check_updates", "google_client", "connect_youtube", "finish_youtube", "add_meta")

# A click on the dashboard. What can't be done (an account whose password is
# wrong, a draft another tab just removed) is said in this tab, not more.
function pane_action!(d::Dashboard, tab::NamedTuple, action::AbstractString, id, value)
    action in PANE_ACTIONS || throw(AppError("unknown Community action: $action"))
    tab.feedback[] = ""
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
pane_action!(d::Dashboard, ::Val{:save_brand}, original::AbstractString, v::AbstractDict) =
    save_brand!(d.app, original, v["name"], v["platforms"], v["notes"])
pane_action!(d::Dashboard, ::Val{:delete_brand}, original::AbstractString, ::Nothing) =
    save_brand!(d.app, original, "", String[], ""; remove=true)

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

pane_action!(d::Dashboard, ::Val{:set_pin}, ::Nothing, pin::AbstractString) = create_vault!(d.app, pin)
pane_action!(d::Dashboard, ::Val{:check_updates}, ::Nothing, pin::AbstractString) = poll_with_pin!(d.app, pin)
pane_action!(d::Dashboard, ::Val{:add_account}, ::Nothing, v::AbstractDict) =
    add_account_with_pin!(d.app, v["platform"], v["brand"], v["handle"], v["server"], v["role"], v["secret"], v["pin"])
pane_action!(d::Dashboard, ::Val{:remove_account}, id::AbstractString, pin::AbstractString) = remove_account_with_pin!(d.app, id, pin)
function pane_action!(d::Dashboard, ::Val{:google_client}, ::Nothing, v::AbstractDict)
    set_google_client_with_pin!(d.app, v["client_id"], v["client_secret"], v["pin"])
    d.feedback[] = "Google client saved in the encrypted vault. You can connect a channel now."
end
function pane_action!(d::Dashboard, ::Val{:connect_youtube}, ::Nothing, v::AbstractDict)
    state, url = begin_youtube_login!(d.app, v["brand"], v["redirect"], v["pin"])
    d.ui[] = merge(d.ui[], Dict("youtube_state"=>state, "youtube_url"=>url))
end
function pane_action!(d::Dashboard, ::Val{:finish_youtube}, ::Nothing, pin::AbstractString)
    complete_youtube_login!(d.app, d.ui[]["youtube_state"], pin)
    d.ui[] = merge(d.ui[], Dict("youtube_state"=>"", "youtube_url"=>""))
    d.feedback[] = "YouTube channel connected."
end
pane_action!(d::Dashboard, ::Val{:add_meta}, ::Nothing, v::AbstractDict) = add_meta_accounts_with_pin!(d.app, v["brand"], v["token"], v["pin"])

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
pane_action!(d::Dashboard, ::Val{:publish}, id::Integer, pin::AbstractString) = publish_with_pin!(d.app, Int(id), pin)
pane_action!(d::Dashboard, ::Val{:publish_all}, id::AbstractString, pin::AbstractString) =
    publish_approved_with_pin!(d.app, id, pin)
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
pane_action!(d::Dashboard, ::Val{:send}, ref::AbstractString, v::AbstractDict) = begin
    draft_answer!(d.app, ref, v["text"])
    send_answer_with_pin!(d.app, ref, v["pin"])
end
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
pane_action!(d::Dashboard, ::Val{:inbox_send}, ref::AbstractString, v::AbstractDict) = begin
    draft_item_answer!(d.app, ref, v["text"])
    send_item_with_pin!(d.app, ref, v["pin"])
end
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

pane_action!(::Dashboard, action::Val, id, value) = throw(AppError("invalid Community action arguments: $action"))

# ── styles ──────────────────────────────────────────────────────────────────

const CommunityStyles = Styles(
    CSS(".cm-dash-wrap, .cm-pin-dialog", "font-family" => "var(--bw-font)",
        "font-size" => "var(--bw-font-size)", "line-height" => "1.5"),
    CSS(".cm-split", "flex" => "1 1 auto", "min-height" => "0", "display" => "flex"),
    CSS(".cm-dash-wrap", "flex" => "3 1 0", "min-width" => "0", "overflow-y" => "auto",
        "border-right" => "1px solid var(--bw-border)", "background" => "var(--bw-bg)"),
    CSS(".cm-chat", "flex" => "2 1 0", "min-width" => "340px", "max-width" => "640px", "min-height" => "0",
        "display" => "flex", "flex-direction" => "column"),
    CSS("@media (max-width: 1000px)",
        CSS(".cm-split", "flex-direction" => "column"),
        CSS(".cm-dash-wrap", "flex" => "0 1 auto", "max-height" => "60%", "border-right" => "none",
            "border-bottom" => "1px solid var(--bw-border)"),
        CSS(".cm-chat", "max-width" => "none", "min-width" => "0")),

    CSS(".cm-region:empty", "display" => "none"),
    CSS(".cm-region", "display" => "contents"),
    CSS("[data-edit-title][contenteditable='plaintext-only']", "outline" => "none", "border-radius" => "6px",
        "box-shadow" => "0 0 0 2px var(--bw-accent)"),
    CSS(".cm-dash", "padding" => "20px 24px 32px", "display" => "flex", "flex-direction" => "column",
        "gap" => "20px", "max-width" => "1180px", "margin" => "0 auto", "color" => "var(--bw-text)"),
    CSS(".cm-top", "display" => "flex", "align-items" => "center", "gap" => "12px", "flex-wrap" => "wrap"),
    CSS(".cm-h1", "font-size" => "var(--bw-font-size-xl)", "font-weight" => "650", "margin" => "0", "letter-spacing" => "-0.01em"),
    CSS(".cm-h2", "font-size" => "var(--bw-font-size-ui)", "font-weight" => "600", "margin" => "0", "text-transform" => "uppercase",
        "letter-spacing" => "0.06em", "color" => "var(--bw-text-muted)"),
    CSS(".cm-sub", "color" => "var(--bw-text-muted)", "font-size" => "var(--bw-font-size-ui)"),
    CSS(".cm-spacer", "flex" => "1 1 auto"),
    CSS(".cm-row", "display" => "flex", "align-items" => "center", "gap" => "8px", "flex-wrap" => "wrap"),
    CSS(".cm-section", "display" => "flex", "flex-direction" => "column", "gap" => "10px"),
    CSS(".cm-section-head", "display" => "flex", "align-items" => "center", "gap" => "10px", "flex-wrap" => "wrap"),

    # cards and panels
    CSS(".cm-panel", "padding" => "16px", "display" => "flex", "flex-direction" => "column", "gap" => "12px"),
    CSS(".cm-notice", "padding" => "10px 14px", "border-radius" => "10px", "font-size" => "var(--bw-font-size-ui)",
        "background" => "color-mix(in srgb, var(--bw-warning) 14%, transparent)",
        "border" => "1px solid color-mix(in srgb, var(--bw-warning) 45%, transparent)"),
    CSS(".cm-toast", "position" => "sticky", "top" => "0", "z-index" => "5", "padding" => "10px 14px",
        "border-radius" => "10px", "font-size" => "var(--bw-font-size-ui)", "color" => "#fff",
        "background" => "var(--bw-error)", "box-shadow" => "var(--bw-shadow-md)", "cursor" => "pointer"),

    # project grid
    CSS(".cm-grid", "display" => "grid", "grid-template-columns" => "repeat(auto-fill, minmax(260px, 1fr))", "gap" => "16px"),
    CSS(".cm-project", "overflow" => "hidden", "display" => "flex", "flex-direction" => "column", "cursor" => "pointer",
        "transition" => "transform .12s ease, box-shadow .12s ease, border-color .12s ease"),
    CSS(".cm-project:hover", "transform" => "translateY(-2px)", "box-shadow" => "var(--bw-shadow-md)",
        "border-color" => "var(--bw-border-strong)"),
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
        "justify-content" => "center", "min-height" => "140px", "background" => "transparent", "font" => "inherit", "cursor" => "pointer", "color" => "var(--bw-text-muted)", "font-weight" => "500"),

    # pills, chips, badges
    CSS(".cm-pill", "display" => "inline-flex", "align-items" => "center", "gap" => "5px", "border-radius" => "999px",
        "padding" => "2px 9px", "font-size" => "var(--bw-font-size-sm)", "font-weight" => "500", "white-space" => "nowrap",
        "background" => "var(--bw-bg-subtle)", "color" => "var(--bw-text)", "border" => "1px solid var(--bw-border)"),
    CSS(".cm-pill-dot::before", "content" => "''", "display" => "inline-block", "width" => "7px", "height" => "7px", "border-radius" => "50%",
        "background" => "var(--dot, var(--bw-text-faint))"),
    CSS(".cm-brand-toggle", "cursor" => "pointer", "user-select" => "none"),
    CSS(".cm-brand-toggle input", "display" => "none"),
    CSS(".cm-brand-toggle.cm-on", "background" => "color-mix(in srgb, var(--bw-accent) 14%, transparent)",
        "border-color" => "var(--bw-accent)"),
    CSS(".cm-status", "border-radius" => "999px", "padding" => "2px 9px", "font-size" => "var(--bw-font-size-xs)", "font-weight" => "600",
        "text-transform" => "uppercase", "letter-spacing" => "0.04em", "background" => "var(--bw-bg-subtle)",
        "color" => "var(--bw-text-muted)"),
    CSS(".cm-status-approved, .cm-status-published, .cm-status-answered",
        "background" => "color-mix(in srgb, var(--bw-success) 16%, transparent)", "color" => "var(--bw-success)"),
    CSS(".cm-status-changes, .cm-status-failed", "background" => "color-mix(in srgb, var(--bw-error) 14%, transparent)",
        "color" => "var(--bw-error)"),
    CSS(".cm-status-publishing, .cm-status-drafted, .cm-status-new",
        "background" => "color-mix(in srgb, var(--bw-accent) 14%, transparent)", "color" => "var(--bw-accent)"),
    CSS(".cm-plat", "display" => "inline-flex", "align-items" => "center", "justify-content" => "center",
        "width" => "26px", "height" => "26px", "border-radius" => "8px", "color" => "#fff", "flex" => "0 0 auto",
        "font-size" => "var(--bw-font-size-sm)", "font-weight" => "700", "background" => "var(--plat)"),
    CSS(".cm-plat-sm", "width" => "18px", "height" => "18px", "border-radius" => "5px", "font-size" => "var(--bw-font-size-2xs)"),
    CSS(".cm-plats", "display" => "flex", "gap" => "4px"),

    # the state stepper
    CSS(".cm-steps", "display" => "flex", "gap" => "3px", "align-items" => "center"),
    CSS(".cm-step", "height" => "5px", "flex" => "1 1 0", "border-radius" => "3px", "background" => "var(--bw-bg-subtle)",
        "min-width" => "18px"),
    CSS(".cm-step-done", "background" => "color-mix(in srgb, var(--bw-accent) 45%, var(--bw-bg-subtle))"),
    CSS(".cm-step-now", "background" => "var(--bw-accent)"),
    CSS(".cm-steps-labeled", "gap" => "6px"),
    CSS(".cm-steps-labeled .cm-step-wrap", "flex" => "1 1 0", "display" => "flex", "flex-direction" => "column", "gap" => "5px"),
    CSS(".cm-step-label", "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-faint)", "text-transform" => "capitalize"),
    CSS(".cm-step-label-now", "color" => "var(--bw-text)", "font-weight" => "600"),

    # forms
    CSS(".cm-field", "display" => "flex", "flex-direction" => "column", "gap" => "4px", "font-size" => "var(--bw-font-size-ui)",
        "color" => "var(--bw-text-muted)"),
    CSS(".cm-input, .cm-textarea, .cm-select", "width" => "100%", "box-sizing" => "border-box", "padding" => "7px 10px",
        "border" => "1px solid var(--bw-border)", "border-radius" => "8px", "background" => "var(--bw-bg)",
        "color" => "var(--bw-text)", "font" => "inherit", "font-size" => "var(--bw-font-size)"),
    CSS(".cm-input:focus, .cm-textarea:focus, .cm-select:focus", "outline" => "none", "border-color" => "var(--bw-accent)",
        "box-shadow" => "0 0 0 3px color-mix(in srgb, var(--bw-accent) 20%, transparent)"),
    CSS(".cm-textarea", "min-height" => "84px", "resize" => "vertical", "line-height" => "1.45"),
    CSS(".cm-form-grid", "display" => "grid", "grid-template-columns" => "repeat(auto-fill, minmax(180px, 1fr))", "gap" => "10px"),

    # project page
    CSS(".cm-hero", "display" => "grid", "grid-template-columns" => "minmax(0, 1.15fr) minmax(0, 1fr)", "gap" => "16px"),
    CSS("@media (max-width: 1300px)", CSS(".cm-hero", "grid-template-columns" => "minmax(0, 1fr)")),
    CSS(".cm-player", "border-radius" => "10px", "overflow" => "hidden", "background" => "#000"),
    CSS(".cm-player video, .cm-player img", "width" => "100%", "display" => "block", "max-height" => "340px", "object-fit" => "contain"),
    CSS(".cm-files", "display" => "flex", "flex-wrap" => "wrap", "gap" => "6px"),
    CSS(".cm-file", "font-size" => "var(--bw-font-size-sm)", "padding" => "3px 8px", "border-radius" => "6px", "background" => "var(--bw-bg-subtle)",
        "max-width" => "100%", "overflow" => "hidden", "text-overflow" => "ellipsis", "white-space" => "nowrap"),
    CSS(".cm-empty", "padding" => "22px", "text-align" => "center", "color" => "var(--bw-text-muted)",
        "font-size" => "var(--bw-font-size-ui)", "border" => "1px dashed var(--bw-border)", "border-radius" => "10px"),
    CSS(".cm-filters", "display" => "flex", "gap" => "4px"),
    CSS(".cm-filter", "border" => "1px solid transparent", "background" => "none", "color" => "var(--bw-text-muted)",
        "border-radius" => "999px", "padding" => "3px 10px", "font" => "inherit", "font-size" => "var(--bw-font-size-ui)", "cursor" => "pointer"),
    CSS(".cm-filter-on", "background" => "var(--bw-bg-subtle)", "color" => "var(--bw-text)", "border-color" => "var(--bw-border)"),

    # draft cards
    CSS(".cm-drafts", "display" => "grid", "grid-template-columns" => "repeat(auto-fill, minmax(300px, 1fr))",
        "gap" => "14px", "align-items" => "start"),
    CSS(".cm-draft", "display" => "flex", "flex-direction" => "column", "overflow" => "hidden",
        "border-top" => "3px solid var(--plat)"),
    CSS(".cm-draft-head", "display" => "flex", "align-items" => "center", "gap" => "10px", "padding" => "12px 14px 0"),
    CSS(".cm-draft-who", "display" => "flex", "flex-direction" => "column", "min-width" => "0", "flex" => "1 1 auto"),
    CSS(".cm-draft-name", "font-weight" => "600", "font-size" => "var(--bw-font-size)"),
    CSS(".cm-draft-meta", "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-muted)"),
    CSS(".cm-draft-body", "padding" => "10px 14px", "display" => "flex", "flex-direction" => "column", "gap" => "8px"),
    CSS(".cm-draft-title", "font-weight" => "600", "font-size" => "15px", "line-height" => "1.35"),
    CSS(".cm-draft-text", "white-space" => "pre-wrap", "overflow-wrap" => "anywhere", "font-size" => "var(--bw-font-size)",
        "line-height" => "1.5", "outline" => "none", "border-radius" => "6px", "max-height" => "260px", "overflow-y" => "auto"),
    CSS(".cm-draft-text[contenteditable='plaintext-only']", "box-shadow" => "0 0 0 2px var(--bw-accent)", "padding" => "4px",
        "max-height" => "none"),
    CSS(".cm-link-chip", "background" => "color-mix(in srgb, var(--bw-accent) 14%, transparent)", "color" => "var(--bw-accent)",
        "border-radius" => "4px", "padding" => "0 4px", "font-size" => "var(--bw-font-size-ui)"),
    CSS(".cm-meter", "height" => "3px", "border-radius" => "2px", "background" => "var(--bw-bg-subtle)", "overflow" => "hidden"),
    CSS(".cm-meter > div", "height" => "100%", "background" => "var(--bw-success)"),
    CSS(".cm-meter-warn > div", "background" => "var(--bw-warning)"),
    CSS(".cm-meter-over > div", "background" => "var(--bw-error)"),
    CSS(".cm-draft-foot", "display" => "flex", "align-items" => "center", "gap" => "6px", "flex-wrap" => "wrap",
        "padding" => "10px 14px 12px", "border-top" => "1px solid var(--bw-border)", "background" => "var(--bw-bg-subtle)"),
    CSS(".cm-callout", "font-size" => "var(--bw-font-size-ui)", "padding" => "8px 10px", "border-radius" => "8px",
        "background" => "color-mix(in srgb, var(--bw-error) 10%, transparent)", "color" => "var(--bw-text)",
        "border-left" => "3px solid var(--bw-error)"),
    CSS(".cm-callout-info", "background" => "color-mix(in srgb, var(--bw-warning) 12%, transparent)",
        "border-left-color" => "var(--bw-warning)"),
    CSS(".cm-posted", "font-size" => "var(--bw-font-size-ui)", "display" => "flex", "flex-direction" => "column", "gap" => "2px"),
    CSS(".cm-posted a", "color" => "var(--bw-accent)", "text-decoration" => "none", "overflow-wrap" => "anywhere"),
    CSS(".cm-stats", "font-size" => "var(--bw-font-size-ui)", "font-weight" => "600", "color" => "var(--bw-text)", "font-variant-numeric" => "tabular-nums"),

    # replies
    CSS(".cm-replies", "display" => "flex", "flex-direction" => "column", "gap" => "10px"),
    CSS(".cm-reply", "display" => "grid", "grid-template-columns" => "36px minmax(0, 1fr)", "gap" => "10px", "padding" => "12px 14px"),
    CSS(".cm-avatar", "width" => "36px", "height" => "36px", "border-radius" => "50%", "display" => "flex",
        "align-items" => "center", "justify-content" => "center", "color" => "#fff", "font-weight" => "600",
        "background" => "var(--plat)"),
    CSS(".cm-reply-text", "white-space" => "pre-wrap", "overflow-wrap" => "anywhere", "font-size" => "var(--bw-font-size)", "line-height" => "1.45"),
    CSS(".cm-answer", "border-left" => "2px solid var(--bw-border-strong)", "padding-left" => "10px"),
    CSS(".cm-topic-title", "font-weight" => "600", "font-size" => "15px", "color" => "var(--bw-text)", "text-decoration" => "none"),
    CSS(".cm-topic-title:hover", "color" => "var(--bw-accent)"),
    CSS(".cm-handled", "opacity" => "0.62"),

    # accounts
    CSS(".cm-accounts", "display" => "flex", "flex-direction" => "column", "gap" => "6px"),
    CSS(".cm-account", "display" => "flex", "align-items" => "center", "gap" => "10px", "padding" => "8px 10px",
        "border-radius" => "8px", "background" => "var(--bw-bg)", "border" => "1px solid var(--bw-border)"),
    CSS(".cm-account-handle", "font-weight" => "500", "flex" => "1 1 auto", "min-width" => "0", "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    CSS(".cm-hint", "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-muted)", "line-height" => "1.45"),
    CSS(".cm-platform-grid", "display" => "grid", "grid-template-columns" => "repeat(auto-fit, minmax(330px, 1fr))", "gap" => "14px", "margin-top" => "14px"),
    CSS(".cm-platform-card", "display" => "flex", "flex-direction" => "column", "gap" => "12px", "padding" => "16px"),
    CSS(".cm-platform-head", "display" => "flex", "align-items" => "center", "gap" => "10px"),
    CSS(".cm-platform-head .cm-h2", "margin" => "0"),
    CSS(".cm-credential-steps", "margin" => "0", "padding-left" => "20px", "display" => "grid", "gap" => "5px", "font-size" => "var(--bw-font-size-ui)", "line-height" => "1.45", "color" => "var(--bw-text-muted)"),
    CSS(".cm-configured", "display" => "flex", "flex-direction" => "column", "gap" => "5px"),
    CSS(".cm-platform-card .cm-account", "padding" => "6px 8px"),
    CSS(".cm-amplify", "border-top" => "1px solid var(--bw-border)", "padding-top" => "10px", "display" => "grid", "gap" => "10px"),
    CSS(".cm-amplify summary", "cursor" => "pointer", "font-size" => "var(--bw-font-size-ui)", "font-weight" => "600", "color" => "var(--bw-text-muted)"),
    CSS(".cm-platform-manual", "background" => "color-mix(in srgb, var(--bw-bg-panel) 80%, var(--bw-bg-subtle))"),
    CSS(".cm-manual-copy", "font-size" => "var(--bw-font-size-ui)", "line-height" => "1.5", "color" => "var(--bw-text-muted)"),
    CSS(".cm-vault-callout", "margin-top" => "10px", "padding" => "10px 12px", "border-radius" => "8px", "background" => "color-mix(in srgb, var(--bw-accent) 12%, transparent)", "font-size" => "var(--bw-font-size-ui)"),
    CSS(".cm-setup", "display" => "grid", "grid-template-columns" => "repeat(auto-fit, minmax(210px, 1fr))", "gap" => "8px",
        "padding" => "12px", "border-radius" => "10px", "background" => "var(--bw-bg)", "border" => "1px solid var(--bw-border)"),
    CSS(".cm-setup .cm-h2", "grid-column" => "1 / -1", "margin-bottom" => "2px"),
    CSS(".cm-setup-step", "display" => "grid", "gap" => "2px", "font-size" => "var(--bw-font-size-sm)", "line-height" => "1.4"),
    CSS(".cm-setup-step span", "color" => "var(--bw-text-muted)"),
    CSS(".cm-pin-form", "display" => "flex", "flex-direction" => "column", "gap" => "12px", "padding-top" => "12px"),
)
