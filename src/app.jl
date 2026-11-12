# The app: its settings, its state and every change to it.

# Projects belong to the app's persistent state, never to the package source
# tree. A package installed by Pkg lives in a shared, often read-only depot.
# The server keeps the durable material; project_files.jl transports it to and
# from an independent workspace on the selected worker.
default_projects_dir(ctx::AppContext) = joinpath(ctx.dir, "projects")
default_settings(ctx::AppContext) = Settings(default_projects_dir(ctx), DEFAULT_BRANDS, DEFAULT_WATCHES, "private")

"settings.json: written with the defaults on first start, edited by hand. Fields added later get their default."
JSON.@defaults struct Settings
    projects_dir::String = ""
    brands::Vector{Brand} = DEFAULT_BRANDS
    watches::Vector{Watch} = DEFAULT_WATCHES
    # What YouTube uploads start as. An API project Google hasn't audited can only upload private videos.
    youtube_privacy::String = "private"
    brands_customized::Bool = false
end

# Discourse became a first-class, manually published release destination after
# the first settings files existed.  Carry the two built-in library brands
# forward without changing any custom brand or its other choices.
function upgrade_settings(settings::Settings)
    settings.brands_customized && return settings
    changed = false
    brands = Brand[]
    for b in settings.brands
        if b.name in ("Makie", "Bonito") && !("discourse" in b.platforms)
            push!(brands, Brand(b.name, [b.platforms; "discourse"], b.notes))
            changed = true
        else
            push!(brands, b)
        end
    end
    return changed ? Settings(settings.projects_dir, brands, settings.watches, settings.youtube_privacy) : settings
end

mutable struct CommunityApp <: AgentApp
    const lock::ReentrantLock
    const ctx::AppContext
    const file::String
    const secrets_file::String
    # Non-nothing only during one PIN-authorised dashboard operation.
    const active_secrets::Base.RefValue{Union{Nothing,Dict{String,String}}}
    settings::Settings
    const state::Observable{CommunityFile}
    # Logged-in Bluesky accounts, by account id.
    const sessions::Dict{String,Session}
    # OAuth continuations contain no PIN, client secret or access token.
    const youtube_logins::Dict{String,Any}
    # When each published draft was last checked for replies (replies.jl).
    const polled::Dict{Int,DateTime}
    # When each inbox source (an account's mentions, a watched forum) was last checked (inbox.jl).
    const inbox_polled::Dict{String,DateTime}
    # What went wrong in the background (publishing, checking replies), for the pane; "" when nothing.
    const notice::Observable{String}
    # Checks the published posts for replies; `nothing` when not polling (tests).
    poller::Union{Timer,Nothing}
end

function CommunityApp(ctx::AppContext; poll::Bool = true)
    settings_file = joinpath(ctx.dir, "settings.json")
    settings = load_json_tolerant(settings_file, "community settings.json", Settings)
    if settings === nothing
        settings = default_settings(ctx)
        atomic_write_json(settings_file, settings)
    else
        upgraded = upgrade_settings(settings)
        if upgraded !== settings
            settings = upgraded
            atomic_write_json(settings_file, settings)
        end
    end
    file = joinpath(ctx.dir, "community.json")
    saved = something(load_json_tolerant(file, "community.json", CommunityFile), CommunityFile())
    next = max(saved.next_draft, maximum((d.id for d in saved.drafts); init = 0) + 1)
    app = CommunityApp(ReentrantLock(), ctx, file, joinpath(ctx.dir, "secrets.enc"), Ref{Union{Nothing,Dict{String,String}}}(nothing), settings,
                       Observable(with(saved; next_draft = next)), Dict{String,Session}(), Dict{String,Any}(),
                       Dict{Int,DateTime}(), Dict{String,DateTime}(), Observable(""), nothing)
    scan_projects!(app)
    poll && start_polling!(app)
    return app
end

BonitoAgents.app_id(::Type{CommunityApp}) = "community"
BonitoAgents.app_title(::CommunityApp) = "Community"
BonitoAgents.app_description(::CommunityApp) =
    "Projects for Makie, Bonito and Makie4Science: drafts for every platform from a video or other material, " *
    "approved here, published, then the replies."
BonitoAgents.app_icon(::CommunityApp) = joinpath(@__DIR__, "community.svg")

projects_dir(app::CommunityApp) = app.settings.projects_dir
brand_names(app::CommunityApp) = [b.name for b in app.settings.brands]

function brand_in_use(app::CommunityApp, name::AbstractString)
    s = app.state[]
    any(p -> name in p.brands, s.projects) || any(d -> d.brand == name, s.drafts) ||
        any(a -> a.brand == name, s.accounts)
end

function save_brand!(app::CommunityApp, original::AbstractString, name::AbstractString, platforms, notes::AbstractString; remove=false)
    lock(app.lock) do
        brands = copy(app.settings.brands)
        i = isempty(original) ? nothing : findfirst(b -> b.name == original, brands)
        isempty(original) || i !== nothing || throw(AppError("this brand no longer exists; refresh the editor"))
        n = strip(name)
        isempty(n) && !remove && throw(AppError("enter a brand name"))
        if remove || (!isempty(original) && n != original)
            brand_in_use(app, original) && throw(AppError("this brand is used by projects, drafts or accounts; its name must stay unchanged"))
        end
        if remove
            i === nothing && throw(AppError("choose an existing brand"))
            deleteat!(brands, i)
        else
            any(b -> b.name != original && lowercase(b.name) == lowercase(n), brands) && throw(AppError("that brand name already exists"))
            ps = unique([platform_id(find_platform(p)) for p in platforms])
            isempty(ps) && throw(AppError("choose at least one platform"))
            any(a -> a.brand == original && !(a.platform in ps), app.state[].accounts) && throw(AppError("remove the connected account before disabling its platform"))
            any(d -> d.brand == original && !(d.platform in ps), app.state[].drafts) && throw(AppError("a draft uses a platform you are disabling"))
            brand = Brand(n, ps, strip(notes))
            i === nothing ? push!(brands, brand) : (brands[i] = brand)
        end
        old = app.settings
        settings = Settings(old.projects_dir, brands, old.watches, old.youtube_privacy, true)
        atomic_write_json(joinpath(app.ctx.dir, "settings.json"), settings)
        app.settings = settings
    end
    notify(app.state)
    return nothing
end

function find_brand(app::CommunityApp, name::AbstractString)
    i = findfirst(b -> lowercase(b.name) == lowercase(strip(name)), app.settings.brands)
    i === nothing && throw(AppError("unknown brand '$name' (known: $(join(brand_names(app), ", ")))"))
    return app.settings.brands[i]
end

# ── changes ─────────────────────────────────────────────────────────────────

# Every change goes through here: `f` gets the state and returns the new one,
# which is saved and then shown.
function update!(f, app::CommunityApp)
    lock(app.lock) do
        app.state.val = f(app.state[])
        atomic_write_json(app.file, app.state[])
    end
    notify(app.state)
    return app.state[]
end

function project_index(s::CommunityFile, id::AbstractString)
    i = findfirst(p -> p.id == id, s.projects)
    i === nothing && throw(AppError("there is no project '$id'"))
    return i
end
find_project(app::CommunityApp, id::AbstractString) = (s = app.state[]; s.projects[project_index(s, id)])

function draft_index(s::CommunityFile, id::Int)
    i = findfirst(d -> d.id == id, s.drafts)
    i === nothing && throw(AppError("there is no draft #$id"))
    return i
end
find_draft(app::CommunityApp, id::Int) = (s = app.state[]; s.drafts[draft_index(s, id)])

project_drafts(s::CommunityFile, id::AbstractString) = filter(d -> d.project == id, s.drafts)
project_replies(s::CommunityFile, id::AbstractString) = filter(r -> r.project == id, s.replies)

function set_project!(app::CommunityApp, id::AbstractString; kw...)
    haskey(kw, :state) && !(kw[:state] in PROJECT_STATES) && throw(AppError("unknown project state '$(kw[:state])'"))
    local p
    update!(app) do s
        projects = copy(s.projects)
        i = project_index(s, id)
        p = projects[i] = change(projects[i]; kw...)
        with(s; projects)
    end
    return p
end

function set_link!(app::CommunityApp, id::AbstractString, key::AbstractString, url::AbstractString)
    p = find_project(app, id)
    u = strip(url)
    isempty(u) || startswith(u, "https://") || throw(AppError("a link starts with https://"))
    links = copy(p.links)
    isempty(u) ? delete!(links, key) : (links[key] = u)
    return set_project!(app, id; links)
end

function checked_brands(app::CommunityApp, brands)
    names = String[find_brand(app, b).name for b in brands if !isempty(strip(b))]
    isempty(names) && throw(AppError("a project needs at least one brand ($(join(brand_names(app), ", ")))"))
    return unique!(names)
end

"A new project: its folder (created) and its record."
function new_project!(app::CommunityApp, title::AbstractString, brands, brief::AbstractString)
    names = checked_brands(app, brands)
    id = project_slug(title)
    any(p -> p.id == id, app.state[].projects) && throw(AppError("there is already a project '$id'"))
    mkpath(joinpath(projects_dir(app), id))
    p = Project(id, strip(title), names, strip(brief), "new", now(UTC), "", Dict{String,String}())
    update!(s -> with(s; projects = vcat(s.projects, p)), app)
    return p
end

"A title from a folder's name: `2026-10-black-hole-render` is \"Black hole render\"."
folder_title(name::AbstractString) = uppercasefirst(replace(replace(name, r"^\d{4}-\d{2}-" => ""), r"[-_]+" => " "))

function rename_project!(app::CommunityApp, id::AbstractString, title::AbstractString)
    t = strip(title)
    isempty(t) && throw(AppError("a project needs a title"))
    return set_project!(app, id; title = t)
end

"Folders put into the projects folder by hand become projects too."
function scan_projects!(app::CommunityApp)
    dir = projects_dir(app)
    isdir(dir) || return app.state[]
    known = Set(p.id for p in app.state[].projects)
    found = [n for n in readdir(dir) if isdir(joinpath(dir, n)) && !startswith(n, ".") && !(n in known)]
    isempty(found) && return app.state[]
    added = [Project(n, folder_title(n), String[], "", "new", now(UTC), "", Dict{String,String}()) for n in sort(found)]
    return update!(s -> with(s; projects = vcat(s.projects, added)), app)
end

"""
    save_draft!(app, project_id; draft_id = 0, brand = "", account = "", platform, kind, title, text, media, reshare = 0) -> Draft

Create a draft (`draft_id == 0`) or replace one. Either way it goes back to
`draft`: whatever was approved before is not what it says now. A published
draft stays as it was published.

Who posts it: one of the project's `brand`s, through its account on the
platform, or a personal `account` itself. With `reshare`, the id of an original
draft on the same platform, it posts nothing of its own: it reposts that one.
"""
function save_draft!(app::CommunityApp, project_id::AbstractString; draft_id::Int = 0, brand::AbstractString = "",
                     account::AbstractString = "", platform::AbstractString, kind::AbstractString,
                     title::AbstractString = "", text::AbstractString, media::Vector{String} = String[],
                     reshare::Int = 0)
    p = find_project(app, project_id)
    pl = find_platform(platform)
    poster_brand, poster_account = draft_poster(app, p, pl, brand, account)
    if reshare == 0
        lowercase(strip(kind)) in ("repost", "reshare") &&
            throw(AppError("a $(strip(kind)) reposts another draft: pass that draft's id as `reshare`"))
        check_draft_text(pl, title, text)
        check_draft_media(pl, media)
        files = material(projects_dir(app), p)
        missing_ = filter(m -> !(m in files), media)
        isempty(missing_) || throw(AppError("not in the project folder: $(join(missing_, ", ")) (it has: $(join(files, ", ")))"))
    else
        isempty(strip(text)) && isempty(strip(title)) && isempty(media) ||
            throw(AppError("a reshare reposts draft #$reshare as it is: leave `text`, `title` and `media` empty"))
        reshare_source(app, p.id, platform_id(pl), draft_id, reshare)
    end
    local d
    update!(app) do s
        drafts = copy(s.drafts)
        next = s.next_draft
        if draft_id == 0
            d = Draft(next, p.id, poster_brand, platform_id(pl), strip(kind), strip(title), strip(text), media,
                      "draft", "", Post[], reshare, now(UTC), poster_account)
            push!(drafts, d)
            next += 1
        else
            i = draft_index(s, draft_id)
            old = drafts[i]
            old.project == p.id || throw(AppError("draft #$draft_id belongs to project '$(old.project)'"))
            is_out(old) && throw(AppError("draft #$draft_id is $(old.status); write a new one instead"))
            d = drafts[i] = change(old; brand = poster_brand, account = poster_account, platform = platform_id(pl),
                                   kind = strip(kind), title = strip(title), text = strip(text), media,
                                   reshare_from = reshare, status = "draft", note = "", updated = now(UTC))
        end
        with(s; next_draft = next, drafts)
    end
    return d
end

# Who posts a draft, as (brand, account): a brand of the project that posts on
# the platform, or a personal account (one of no brand) on the platform.
function draft_poster(app::CommunityApp, p::Project, pl::Platform, brand::AbstractString, account::AbstractString)
    b, a = strip(brand), strip(account)
    isempty(b) && isempty(a) && throw(AppError("say who posts it: one of the project's brands, or a personal `account`"))
    !isempty(b) && !isempty(a) && throw(AppError("give the brand or the personal account that posts it, not both"))
    if isempty(a)
        br = find_brand(app, b)
        br.name in p.brands || throw(AppError("project '$(p.id)' is not for $(br.name) (its brands: $(join(p.brands, ", ")))"))
        platform_id(pl) in br.platforms ||
            throw(AppError("$(br.name) does not post on $(platform_name(pl)) (it does on $(join(br.platforms, ", ")))"))
        return (br.name, "")
    end
    acc = find_account(app, a)
    isempty(acc.brand) || throw(AppError("$(acc.id) is $(acc.brand)'s account: draft it as `brand = \"$(acc.brand)\"`"))
    acc.platform == platform_id(pl) || throw(AppError("$(acc.id) is a $(acc.platform) account, not $(platform_id(pl))"))
    return ("", acc.id)
end

# The original draft `source_id` that draft `id` (0 for a new one) of project
# `project` on `platform` may reshare.
function reshare_source(app::CommunityApp, project::AbstractString, platform::AbstractString, id::Int, source_id::Int)
    source_id == id && throw(AppError("a draft cannot reshare itself"))
    pl = find_platform(platform)
    publishes(pl) && reposts(pl) || throw(AppError("the app does not repost on $(platform_name(pl))"))
    source = find_draft(app, source_id)
    source.project == project && source.platform == platform && source.reshare_from == 0 ||
        throw(AppError("draft #$source_id is not an original $platform draft of this project; only those can be reshared"))
    return source
end

function set_draft!(app::CommunityApp, id::Int; kw...)
    haskey(kw, :status) && !(kw[:status] in DRAFT_STATES) && throw(AppError("unknown draft status '$(kw[:status])'"))
    local d
    update!(app) do s
        drafts = copy(s.drafts)
        i = draft_index(s, id)
        d = drafts[i] = change(drafts[i]; updated = now(UTC), kw...)
        with(s; drafts)
    end
    return d
end

"Choose whether a brand's draft is its own post or a reshare of another original draft."
function set_draft_reshare!(app::CommunityApp, id::Int, source_id::Int)
    d = find_draft(app, id)
    is_out(d) && throw(AppError("draft #$id is already $(d.status)"))
    if source_id == 0
        return set_draft!(app, id; reshare_from = 0, status = "draft")
    end
    source = reshare_source(app, d.project, d.platform, id, source_id)
    return set_draft!(app, id; reshare_from = source.id, status = "draft")
end

# A draft on its way out or out: no more edits or verdicts.
is_out(d::Draft) = d.status in ("publishing", "published")

"The user's verdict on a draft; one that is out has had its verdict."
function review_draft!(app::CommunityApp, id::Int, status::AbstractString; note::AbstractString = "")
    is_out(find_draft(app, id)) && throw(AppError("draft #$id is already $(find_draft(app, id).status)"))
    return set_draft!(app, id; status, note = strip(note))
end

"The user edited a draft's text in the pane: checked like the agent's, and back to `draft`."
function edit_draft_text!(app::CommunityApp, id::Int, text::AbstractString)
    d = find_draft(app, id)
    is_out(d) && throw(AppError("draft #$id is already $(d.status)"))
    check_draft_text(find_platform(d.platform), d.title, text)
    return set_draft!(app, id; text = strip(text), status = "draft", note = "")
end

function remove_draft!(app::CommunityApp, id::Int)
    is_out(find_draft(app, id)) && throw(AppError("draft #$id is $(find_draft(app, id).status); it stays on record"))
    return update!(s -> with(s; drafts = deleteat!(copy(s.drafts), draft_index(s, id))), app)
end

# ── accounts and their secrets ──────────────────────────────────────────────

"The request-scoped decrypted credentials. This is inaccessible while locked."
function load_secrets(app::CommunityApp)
    secrets = app.active_secrets[]
    secrets === nothing && throw(AppError("Community is locked: enter the PIN for this account action"))
    return secrets
end

function store_secret!(app::CommunityApp, id::AbstractString, value::Union{AbstractString,Nothing})
    secrets = load_secrets(app)
    value === nothing ? delete!(secrets, id) : (secrets[id] = value)
end

function secret(app::CommunityApp, a::Account)
    s = get(load_secrets(app), a.id, "")
    isempty(s) && throw(AppError("no password or token for $(a.handle); add the account again"))
    return s
end

function find_account(app::CommunityApp, id::AbstractString)
    i = findfirst(a -> a.id == id, app.state[].accounts)
    i === nothing && throw(AppError("there is no account '$id'"))
    return app.state[].accounts[i]
end

"""
    add_account!(app, platform, brand, handle, server, role, secret) -> Account

Check the credentials with the platform first (`verify_account`), then keep
the account, and its secret in `secrets.json`. Adding it again replaces it.
"""
function add_account!(app::CommunityApp, platform::AbstractString, brand::AbstractString,
                      handle::AbstractString, server::AbstractString, role::AbstractString, secret::AbstractString)
    pl = find_platform(platform)
    role in ACCOUNT_ROLES || throw(AppError("an account's role is $(join(ACCOUNT_ROLES, " or "))"))
    b = isempty(strip(brand)) ? "" : find_brand(app, brand).name
    role == "post" && isempty(b) && throw(AppError("an account that posts posts for a brand"))
    h = lstrip(strip(handle), '@')
    isempty(h) && throw(AppError("an account needs its handle"))
    isempty(strip(secret)) && throw(AppError("an account needs its app password or token"))
    a = Account(platform_id(pl) * ":" * h, platform_id(pl), b, h, account_server(pl, h, strip(server)), role)
    verify_account(pl, a, strip(secret))
    store_secret!(app, a.id, strip(secret))
    update!(s -> with(s; accounts = vcat(filter(x -> x.id != a.id, s.accounts), a)), app)
    return a
end

"Check and save an account during one explicit PIN-authorised UI action."
function add_account_with_pin!(app::CommunityApp, platform, brand, handle, server, role, value, pin)
    vault_exists(app) || throw(AppError("set a Community PIN before adding accounts"))
    return with_vault!(app, pin) do
        add_account!(app, platform, brand, handle, server, role, value)
    end
end

function remove_account!(app::CommunityApp, id::AbstractString)
    find_account(app, id)
    store_secret!(app, id, nothing)
    return update!(s -> with(s; accounts = filter(a -> a.id != id, s.accounts)), app)
end

function remove_account_with_pin!(app::CommunityApp, id::AbstractString, pin::AbstractString)
    return with_vault!(app, pin) do
        remove_account!(app, id)
    end
end

"The account that publishes `brand`'s drafts on `platform`."
function posting_account(app::CommunityApp, brand::AbstractString, platform::AbstractString)
    i = findfirst(a -> a.role == "post" && a.brand == brand && a.platform == platform, app.state[].accounts)
    i === nothing && throw(AppError("no $(platform_name(find_platform(platform))) account posts for $brand yet; add one under Accounts"))
    return app.state[].accounts[i]
end

"The account that publishes draft `d`: the personal account it names, else its brand's; `nothing` while there is none."
function draft_account(app::CommunityApp, d::Draft)
    accounts = app.state[].accounts
    i = isempty(d.account) ? findfirst(a -> a.role == "post" && a.brand == d.brand && a.platform == d.platform, accounts) :
                             findfirst(a -> a.id == d.account, accounts)
    return i === nothing ? nothing : accounts[i]
end

function posting_account(app::CommunityApp, d::Draft)
    isempty(d.account) && return posting_account(app, d.brand, d.platform)
    a = draft_account(app, d)
    a === nothing && throw(AppError("draft #$(d.id) posts as $(d.account), which is no longer an account; add it again under Accounts"))
    return a
end

"Explicitly configured personal accounts that repost `origin`'s post. Brand accounts reshare only when selected on that draft."
amplifying_accounts(app::CommunityApp, origin::Account, p::Project) =
    filter(a -> a.platform == origin.platform && a.id != origin.id && a.role == "amplify",
           app.state[].accounts)
