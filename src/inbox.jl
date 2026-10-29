# The inbox: what needs the community manager without belonging to a project.
# Mentions of the accounts on Bluesky and Mastodon (an answer to a project's
# post is that project's reply instead), new topics in the watched forums, and
# new releases of the watched repositories (each can start a blog post project).
# Each source is checked every 10 minutes; what is older than a week when first
# seen is left out.

const INBOX_EVERY = Minute(10)
const INBOX_WINDOW = Day(7)
const INBOX_KEEP = Day(60)          # done and ignored items are dropped after this

# ── Discourse ───────────────────────────────────────────────────────────────

"The topics of a Discourse tag or category page (its `.json`), newest activity first; pinned ones left out."
fetch_topics(w::Watch) = discourse_topics(api("GET", rstrip(w.url, '/') * ".json"), w)

function discourse_topics(r, w::Watch)
    host = match(r"^https?://[^/]+", w.url).match
    users = Dict(u["id"] => u for u in get(r, "users", []))
    out = NamedTuple[]
    for t in r["topic_list"]["topics"]
        get(t, "pinned", false) === true && continue
        posters = get(t, "posters", [])
        poster = isempty(posters) ? nothing : get(users, posters[1]["user_id"], nothing)
        name = poster === nothing ? "" : string(something(get(poster, "name", nothing), ""))
        handle = poster === nothing ? "" : string(poster["username"])
        replies = Int(t["posts_count"]) - 1
        excerpt = html_text(string(something(get(t, "excerpt", nothing), "")))
        push!(out, (id = string(t["id"]), title = string(t["title"]), url = "$host/t/$(t["slug"])/$(t["id"])",
                    author = handle, author_name = isempty(name) ? handle : name,
                    text = isempty(excerpt) ? (replies == 0 ? "No answer yet." : "$replies repl$(replies == 1 ? "y" : "ies") so far.") : excerpt,
                    created = parse_time(string(t["created_at"]))))
    end
    return out
end

# ── GitHub releases ─────────────────────────────────────────────────────────

github_repo(url::AbstractString) =
    (m = match(r"github\.com/([^/]+/[^/]+?)(?:\.git)?/?$", url); m === nothing ? throw(AppError("not a GitHub repository: $url")) : m.captures[1])

"The published releases of a repository (no drafts or pre-releases), newest first."
fetch_releases(w::Watch) =
    github_releases(api("GET", "https://api.github.com/repos/$(github_repo(w.url))/releases"; query = ["per_page" => "10"],
                        headers = ["Accept" => "application/vnd.github+json"]), w)

function github_releases(r, w::Watch)
    repo = github_repo(w.url)
    name = replace(split(repo, '/')[2], r"\.jl$" => "")
    out = NamedTuple[]
    for x in r
        (x["draft"] === true || x["prerelease"] === true) && continue
        tag = string(x["tag_name"])
        body = strip(string(something(x["body"], "")))
        release = string(something(x["name"], ""))
        push!(out, (tag = tag, title = "$name $(isempty(release) ? tag : release)",
                    url = string(x["html_url"]), author = string(x["author"]["login"]),
                    text = isempty(body) ? "Released $tag." : first(body, 600) * (length(body) > 600 ? " …" : ""),
                    created = parse_time(string(something(x["published_at"], x["created_at"])))))
    end
    return out
end

# ── checking ────────────────────────────────────────────────────────────────

"Ids of what the projects published and the replies they got: a mention answering one of those is a project's."
function project_threads(s::CommunityFile)
    ids = Set{String}()
    for d in s.drafts, p in d.posts
        isempty(p.ref) || push!(ids, p.ref)
    end
    foreach(r -> push!(ids, r.ref), s.replies)
    return ids
end

function add_inbox!(app::CommunityApp, items::Vector{InboxItem})
    isempty(items) && return 0
    local added
    update!(app) do s
        known = Set(i.ref for i in s.inbox)
        new = filter(i -> !(i.ref in known), items)
        added = length(new)
        keep = filter(i -> !(i.status in ("done", "ignored") && now(UTC) - i.created > INBOX_KEEP), s.inbox)
        with(s; inbox = vcat(keep, new))
    end
    return added
end

function check_mentions!(app::CommunityApp, a::Account)
    found = fetch_mentions(find_platform(a.platform), app, a)
    s = app.state[]
    ours = Set(lowercase(x.handle) for x in s.accounts)
    threads = project_threads(s)
    since = now(UTC) - INBOX_WINDOW
    items = InboxItem[]
    for m in found
        (m.created < since || lowercase(m.author) in ours) && continue
        # an answer to a project's post (or to one of its replies) is that project's reply
        (m.parent in threads || m.root in threads || m.post in threads) && continue
        push!(items, InboxItem("$(a.platform):$(m.post)", a.platform, "mention", a.id, a.brand, m.author, m.author_name,
                               "", m.text, m.url, m.created, "new", "", m.post, m.post_cid, m.root, m.root_cid))
    end
    return add_inbox!(app, items)
end

"What a watch has that is new: as inbox items, by its source."
watch_items(w::Watch) = watch_items(Val(Symbol(w.source)), w)

function watch_items(::Val{:discourse}, w::Watch)
    host = match(r"^https?://([^/]+)", w.url).captures[1]
    return [InboxItem("discourse:$host:$(t.id)", "discourse", "topic", "", w.brand, t.author, t.author_name,
                      t.title, t.text, t.url, t.created, "new", "", t.id, "", "", "") for t in fetch_topics(w)]
end

watch_items(::Val{:github}, w::Watch) =
    [InboxItem("github:$(github_repo(w.url)):$(r.tag)", "github", "release", "", w.brand, r.author, r.author,
               r.title, r.text, r.url, r.created, "new", "", r.tag, "", "", "") for r in fetch_releases(w)]

watch_items(::Val, w::Watch) = throw(AppError("unknown watch source '$(w.source)'"))

function check_watch!(app::CommunityApp, w::Watch)
    since = now(UTC) - INBOX_WINDOW
    return add_inbox!(app, filter(x -> x.created >= since, watch_items(w)))
end

"""
    project_from_release!(app, ref) -> Project

A project for a release in the inbox: its blog post and the announcements of it.
The release is done with in the inbox.
"""
function project_from_release!(app::CommunityApp, ref::AbstractString)
    x = find_item(app, ref)
    x.kind == "release" || throw(AppError("only a release starts a project"))
    b = find_brand(app, x.brand)
    brief = "Release $(x.post) ($(x.url)). Write the blog post about it into `post.md` in this folder, in the " *
            "style of the $(b.name) blog ($(b.notes)): what is new and why it matters, with short code examples. " *
            "Then the announcement drafts, linking to the post with $BLOG_LINK."
    p = new_project!(app, x.title * " release", [b.name], brief)
    set_item!(app, ref; status = "done")
    return p
end

# A source is checked when its last check is 10 minutes old; each on its own, one failing doesn't stop the rest.
function poll_inbox!(app::CommunityApp)
    t = now(UTC)
    problems = String[]
    due(key) = (last = lock(() -> get(app.inbox_polled, key, nothing), app.lock); last === nothing || t - last >= INBOX_EVERY)
    mark(key) = lock(() -> (app.inbox_polled[key] = t), app.lock)
    for a in app.state[].accounts
        publishes(find_platform(a.platform)) || continue
        vault_active(app) || continue       # never wake credentials in a timer
        key = "mentions:" * a.id
        due(key) || continue
        mark(key)
        r = attempt(() -> check_mentions!(app, a), "checking mentions of $(a.handle)")
        r isa Int || push!(problems, "mentions of $(a.handle): $r")
    end
    for w in app.settings.watches
        key = "watch:" * w.url
        due(key) || continue
        mark(key)
        r = attempt(() -> check_watch!(app, w), "checking $(w.url)")
        r isa Int || push!(problems, "$(w.url): $r")
    end
    return problems
end

# ── answering ───────────────────────────────────────────────────────────────

function inbox_index(s::CommunityFile, ref::AbstractString)
    i = findfirst(x -> x.ref == ref, s.inbox)
    i === nothing && throw(AppError("there is no inbox item '$ref'"))
    return i
end
find_item(app::CommunityApp, ref::AbstractString) = (s = app.state[]; s.inbox[inbox_index(s, ref)])

function set_item!(app::CommunityApp, ref::AbstractString; kw...)
    haskey(kw, :status) && !(kw[:status] in INBOX_STATES) && throw(AppError("unknown inbox status '$(kw[:status])'"))
    local x
    update!(app) do s
        inbox = copy(s.inbox)
        i = inbox_index(s, ref)
        x = inbox[i] = change(inbox[i]; kw...)
        with(s; inbox)
    end
    return x
end

"Draft the answer to an inbox item. A mention's is checked against its platform's limit; a forum answer is copied by hand."
function draft_item_answer!(app::CommunityApp, ref::AbstractString, text::AbstractString)
    x = find_item(app, ref)
    x.status == "answered" && throw(AppError("that is already answered"))
    t = strip(text)
    isempty(t) && throw(AppError("an answer needs a text"))
    x.kind == "mention" && check_draft_text(find_platform(x.source), "", t)
    return set_item!(app, ref; answer = t, status = "drafted")
end

"Send a mention's drafted answer from the account that was mentioned, in its thread."
function send_item!(app::CommunityApp, ref::AbstractString)
    x = find_item(app, ref)
    x.kind == "mention" || throw(AppError("a forum topic is answered on the forum: copy the answer"))
    x.status == "drafted" || throw(AppError("draft an answer first"))
    root, root_cid = isempty(x.root) ? (x.post, x.post_cid) : (x.root, x.root_cid)
    send_answer(find_platform(x.source), app, find_account(app, x.account),
                AnswerTo(root, root_cid, x.post, x.post_cid, x.author), x.answer)
    return set_item!(app, ref; status = "answered")
end

function send_item_in_background!(app::CommunityApp, ref::AbstractString)
    throw(AppError("sending an answer needs an explicit PIN-authorised dashboard action"))
end

function send_item_with_pin!(app::CommunityApp, ref::AbstractString, pin::AbstractString)
    find_item(app, ref).status == "drafted" || throw(AppError("draft an answer first"))
    return with_vault!(app, pin) do
        send_item!(app, ref)
    end
end
