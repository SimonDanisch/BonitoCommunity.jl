# What agents get. The app's own chat manages projects; each project has a chat
# of its own (an app chat with key "project/<id>"), whose agent drafts that
# project's posts and the answers to their replies. Nothing here publishes or
# sends: that is a click in the pane.

const PROJECT_KEY = "project/"
project_key(p::Project) = PROJECT_KEY * p.id
const ProjectChats = AppKeyedChats(PROJECT_KEY)

function caller_project(app::CommunityApp, call::AppCall)
    key = call.caller.app_key
    startswith(key, PROJECT_KEY) || throw(AppError("this chat is not a project's"))
    return find_project(app, key[length(PROJECT_KEY)+1:end])
end

const PROJECT_ID = Param(String, "The project's id (its folder name), as `cm_projects` lists it.")

BonitoAgents.app_tools(::CommunityApp) = [
    AppTool(:cm_projects,
        "The community projects: id, title, brands, state, material files, drafts per status, new replies.",
        (;); scope = AppChat()),
    AppTool(:cm_new_project,
        "Create a project: a folder for its material and its record. `brands` are brand names, comma-separated.",
        (title = Param(String, "The project's title."),
         brands = Param(String, "Brand names, comma-separated, e.g. \"Makie4Science, Makie\"."),
         brief = Param(String, "What it is about and what the posts should say.", ""));
        scope = AppChat()),
    AppTool(:cm_inbox,
        "The inbox: mentions of the accounts and new forum topics that belong to no project, with their status " *
        "(new, drafted, answered, done, ignored). `all` includes the answered, done and ignored ones.",
        (all = Param(Bool, "Also list answered, done and ignored items.", false),); scope = AppChat()),
    AppTool(:cm_answer,
        "Draft the answer to an inbox item (`ref` as `cm_inbox` lists it). The user sends a mention's answer " *
        "with a click; a forum answer is copied to the forum by hand.",
        (ref = Param(String, "The item's ref."), text = Param(String, "The answer.")); scope = AppChat()),
    AppTool(:cm_start_project_chat,
        "Start a project's own chat, in its folder on this chat's worker, sent `prompt` as its first message. " *
        "Its agent drafts the project's posts with the `project_*` tools.",
        (project = PROJECT_ID,
         prompt = Param(String, "The task for the project chat's agent: what to make, from which material, the tone."));
        scope = AppChat()),
    AppTool(:project_info,
        "This chat's project: brief, links, brands with the platforms they post on, what each platform gets, " *
        "text limits, the material files and the drafts so far with their status and the user's notes.",
        (;); scope = ProjectChats),
    AppTool(:project_draft,
        "Write a draft for this chat's project, or replace one (`draft_id`). A replaced draft goes back to the " *
        "user for approval. Link to the project's YouTube video with $YOUTUBE_LINK.",
        (brand = Param(String, "The brand whose account posts it."),
         platform = Param(String, "youtube, tiktok, instagram, facebook, bluesky, mastodon or linkedin."),
         kind = Param(String, "What it is: video, short, reel, post, ..."),
         text = Param(String, "The post text (for YouTube: the description)."),
         title = Param(String, "YouTube only: the title.", ""),
         media = Param(String, "Files from the project folder it uses, comma-separated.", ""),
         draft_id = Param(Int, "The draft to replace; 0 for a new one.", 0));
        scope = ProjectChats),
    AppTool(:project_submit,
        "Tell the user the drafts are ready for review (sets the project to `review`). `message`: what you made, briefly.",
        (message = Param(String, "What was drafted, one or two sentences."),); scope = ProjectChats),
    AppTool(:project_replies,
        "The replies to this project's published posts, with what they answer and their status " *
        "(new, drafted, answered, ignored). `all` includes the answered and ignored ones.",
        (all = Param(Bool, "Also list answered and ignored replies.", false),); scope = ProjectChats),
    AppTool(:project_answer,
        "Draft the answer to a reply (`ref` as `project_replies` lists it). The user sends it with a click.",
        (ref = Param(String, "The reply's ref."), text = Param(String, "The answer.")); scope = ProjectChats),
]

BonitoAgents.app_briefing(app::CommunityApp) = """
# The Community app

This chat is the Community app's overview. Its pane lists the projects (one
folder of material each, under `$(projects_dir(app))`), their state, drafts and
new replies; each project has its own chat, where its posts are drafted and the
user reviews them. Brands: $(join(brand_names(app), ", ")).

The inbox holds what needs answering but belongs to no project: mentions of
the accounts and new topics in the watched forums. When asked, draft answers
with `cm_inbox` and `cm_answer`: as the brand, briefly, helpful and kind; leave
out what needs no answer. For a forum question, a good answer is concrete
(a short Makie or Bonito snippet, a link to the docs).

A project goes new → drafting → review → publishing → community → archived.
To get a project drafted (the pane's "Start drafting" asks you to):
1. look at it with `cm_projects` (its material and brief),
2. call `cm_start_project_chat` with a prompt for the project chat's agent:
   what the material is, which brands, what the posts should achieve.
That chat writes the drafts; you don't write them here. Keep your answers
short: the pane shows the outcome.
"""

"The dashboard's authoritative project context, also supplied to chats with no material files."
function project_chat_context(app::CommunityApp, p::Project)
    links = isempty(p.links) ? "No separate links set; also use any links in the brief." :
        join(("$key: $url" for (key, url) in sort!(collect(p.links); by=first)), "\n")
    return """
    ## Project context from the Community dashboard
    Title: $(p.title)
    Brands: $(join(p.brands, ", "))

    Brief:
    $(isempty(p.brief) ? "No brief entered yet." : p.brief)

    Links:
    $links

    The brief and links are stored by Community, not in a workspace file.
    Call `project_info` first to read the latest brief, links, brand instructions
    and existing drafts. An empty material folder is valid for text announcements;
    it does not mean the brief is missing. Save drafts with `project_draft`, then
    call `project_submit` to put them in the dashboard for review.
    """
end

function BonitoAgents.app_briefing(app::CommunityApp, key::AbstractString)
    isempty(key) && return BonitoAgents.app_briefing(app)
    startswith(key, PROJECT_KEY) || return ""
    id = key[length(PROJECT_KEY)+1:end]
    p = find_project(app, id)
    return """
    # Community project $id

    This chat belongs to the community project `$id` of the Community app; its
    material is in this folder. The pane beside you shows the project: its
    brief, material, your drafts and the replies to its published posts. The
    user approves, edits or sends back drafts there and publishes them; you
    never publish or send anything.

    $(project_chat_context(app, p))

    - `project_info`: the brief, the brands and their platforms, what each
      platform gets and its limits, the drafts so far and the user's notes.
    - `project_draft`: one draft per brand and platform; `draft_id` replaces
      one (it goes back to review). Bluesky and Mastodon can carry up to four
      native images and link to the YouTube video with $YOUTUBE_LINK.
    - `project_submit`: when the drafts are ready for review.
    - `project_replies` and `project_answer`: answers to the replies, once the
      posts are out. Answer as the brand, briefly and kindly; leave out what
      needs no answer.

    When the user asks for changes to a draft, replace that draft with
    `project_draft` and its `draft_id`.

    ## Video work

    You may make files from the material, in this folder, and use them as a
    draft's media: Shorts and Reels cut vertical (1080×1920, ≤ 3 min) into
    `shorts/`, a thumbnail, a transcript. There is no `ffmpeg` on PATH: use
    FFMPEG_jll in a temporary Julia environment
    (`using FFMPEG_jll; run(`\$(FFMPEG_jll.ffmpeg()) -i in.mp4 ...`)`).
    A transcript (`.srt`, `.txt`) in the folder is the best source for YouTube
    chapters and for picking the moments a Short is cut from.

    The YouTube video draft (kind `video`, the full video as its media) is
    uploaded by the app when the user publishes it; its link then goes into
    the Bluesky and Mastodon drafts. Shorts are YouTube drafts of kind `short`.
    """
end

# ── the overview's tools ────────────────────────────────────────────────────

function project_summary(app::CommunityApp, s::CommunityFile, p::Project)
    drafts = project_drafts(s, p.id)
    counts = join(("$(count(d -> d.status == st, drafts)) $st" for st in DRAFT_STATES if any(d -> d.status == st, drafts)), ", ")
    files = material(projects_dir(app), p)
    replies = count(r -> r.status == "new", project_replies(s, p.id))
    chat = isempty(p.chat) ? "none yet" : "\"$(something(chat_title(app.ctx.server, p.chat), "closed"))\" ($(p.chat))"
    return """
    - $(p.id): "$(p.title)" · $(p.state) · brands: $(isempty(p.brands) ? "none set" : join(p.brands, ", "))
      chat: $chat · drafts: $(isempty(counts) ? "none" : counts) · new replies: $replies
      material: $(isempty(files) ? "none yet" : join(first(files, 20), ", "))$(length(files) > 20 ? " …" : "")
      brief: $(isempty(p.brief) ? "(none)" : p.brief)"""
end

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:cm_projects}, ::AppCall)
    s = scan_projects!(app)
    isempty(s.projects) && return "No projects yet. Their folders go in $(projects_dir(app))."
    return join((project_summary(app, s, p) for p in s.projects), "\n")
end

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:cm_new_project}, call::AppCall)
    (; title, brands, brief) = call.args
    p = new_project!(app, title, split(brands, ','), brief)
    return "Created project $(p.id) in $(project_folder(projects_dir(app), p))."
end

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:cm_start_project_chat}, call::AppCall)
    (; project, prompt) = call.args
    p = find_project(app, project)
    isempty(p.brands) && throw(AppError("project '$(p.id)' has no brands yet; set them in the pane first"))
    isempty(p.chat) || chat_title(call.server, p.chat) === nothing ||
        throw(AppError("project '$(p.id)' has its chat already ($(p.chat))"))
    owner = caller_user(call)
    worker = find_worker(call.server, owner, call.caller.worker_id)
    worker === nothing && throw(AppError("this chat's worker is gone"))
    folder = prepare_project_worker!(app, worker, p)
    initial_prompt = project_chat_context(app, p) * "\n\n## Drafting task\n" * prompt
    chat = start_chat!(call.server, owner, worker, folder;
                       title = p.title, prompt = initial_prompt, app, key = project_key(p))
    set_project!(app, p.id; chat = chat.id, state = p.state == "new" ? "drafting" : p.state)
    return "Started chat \"$(chat.title[])\" ($(chat.id)) for project $(p.id)."
end

function inbox_line(x::InboxItem)
    head = "- ref $(x.ref) [$(x.status)] $(x.source) $(x.kind)$(isempty(x.brand) ? "" : " for " * x.brand) · " *
           "$(x.author_name) (@$(x.author)) · " * Dates.format(x.created, "yyyy-mm-dd HH:MM") * " UTC · $(x.url)"
    lines = [head]
    isempty(x.title) || push!(lines, "  topic: " * x.title)
    push!(lines, "  " * replace(x.text, "\n" => "\n  "))
    isempty(x.answer) || push!(lines, "  answer: " * x.answer)
    return join(lines, "\n")
end

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:cm_inbox}, call::AppCall)
    items = filter(x -> call.args.all || x.status in ("new", "drafted"), app.state[].inbox)
    isempty(items) && return call.args.all ? "The inbox is empty." : "Nothing open in the inbox."
    return join(inbox_line.(sort(items; by = x -> x.created, rev = true)), "\n")
end

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:cm_answer}, call::AppCall)
    x = draft_item_answer!(app, call.args.ref, call.args.text)
    return "Drafted the answer to $(x.author_name)."
end

# ── the project chats' tools ────────────────────────────────────────────────

function draft_line(d::Draft)
    head = "#$(d.id) [$(d.status)] $(d.brand) · $(d.platform) · $(d.kind)"
    body = isempty(d.title) ? d.text : "title: $(d.title)\n$(d.text)"
    lines = [head, body]
    isempty(d.media) || push!(lines, "media: " * join(d.media, ", "))
    d.reshare_from == 0 || push!(lines, "reshare: draft #$(d.reshare_from)")
    isempty(d.note) || push!(lines, "user's note: " * d.note)
    isempty(d.posts) || push!(lines, "published: " * join((p.url for p in d.posts if p.kind == "original"), ", "))
    return join(lines, "\n")
end

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:project_info}, call::AppCall)
    p = caller_project(app, call)
    s = app.state[]
    brands = map(p.brands) do name
        b = find_brand(app, name)
        plats = join(("  - $(platform_name(pl)) (≤ $(max_text(pl)) chars$(max_title(pl) > 0 ? ", title ≤ $(max_title(pl))" : "")): $(role(pl))"
                      for pl in PLATFORMS if platform_id(pl) in b.platforms), "\n")
        "## $(b.name)\n$(b.notes)\n$plats"
    end
    files = material(projects_dir(app), p)
    drafts = project_drafts(s, p.id)
    links = isempty(p.links) ? "none yet" : join(("$k: $v" for (k, v) in p.links), ", ")
    return """
    # $(p.title) ($(p.id)) · $(p.state)
    Brief: $(isempty(p.brief) ? "(none)" : p.brief)
    Links: $links
    Folder on your worker: $(call.caller.worker_path)
    Material: $(isempty(files) ? "none yet" : join(files, ", "))

    $(join(brands, "\n\n"))

    # Drafts
    $(isempty(drafts) ? "none yet" : join(draft_line.(drafts), "\n\n"))"""
end

split_list(s::AbstractString) = String[strip(x) for x in split(s, ',') if !isempty(strip(x))]

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:project_draft}, call::AppCall)
    p = caller_project(app, call)
    (; brand, platform, kind, text, title, media, draft_id) = call.args
    isempty(strip(media)) || collect_project_files!(app, p, call.caller)
    d = save_draft!(app, p.id; draft_id, brand, platform, kind, title, text, media = split_list(media))
    return "Saved draft #$(d.id) ($(d.brand) · $(d.platform) · $(d.kind))."
end

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:project_submit}, call::AppCall)
    p = caller_project(app, call)
    isempty(project_drafts(app.state[], p.id)) && throw(AppError("there are no drafts yet"))
    collect_project_files!(app, p, call.caller)
    p.state in ("new", "drafting") && set_project!(app, p.id; state = "review")
    return "Project $(p.id) is ready for review. ($(call.args.message))"
end

function reply_line(r::Reply)
    head = "- ref $(r.ref) [$(r.status)] $(r.platform) · $(r.author_name) (@$(r.author)) on draft #$(r.draft) · " *
           Dates.format(r.created, "yyyy-mm-dd HH:MM") * " UTC"
    lines = [head, "  " * replace(r.text, "\n" => "\n  ")]
    isempty(r.answer) || push!(lines, "  answer: " * r.answer)
    return join(lines, "\n")
end

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:project_replies}, call::AppCall)
    p = caller_project(app, call)
    replies = filter(r -> call.args.all || r.status in ("new", "drafted"), project_replies(app.state[], p.id))
    isempty(replies) && return call.args.all ? "No replies yet." : "No open replies."
    return join(reply_line.(sort(replies; by = r -> r.created)), "\n")
end

function BonitoAgents.call_tool(app::CommunityApp, ::Val{:project_answer}, call::AppCall)
    p = caller_project(app, call)
    r = find_reply(app, call.args.ref)
    r.project == p.id || throw(AppError("that reply belongs to project '$(r.project)'"))
    draft_answer!(app, r.ref, call.args.text)
    return "Drafted the answer to $(r.author_name)."
end
