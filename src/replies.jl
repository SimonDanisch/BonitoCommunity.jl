# The replies to a project's published posts: checked often while a post is new,
# less as it ages, never once the project is archived. An answer is drafted (by
# the project chat's agent or by hand) and sent with a click.

"How long after its last check a post published at `at` is checked again; `nothing` once it is old."
function check_interval(at::DateTime, t::DateTime = now(UTC))
    age = t - at
    age < Day(1) && return Minute(5)
    age < Day(7) && return Hour(1)
    age < Day(30) && return Day(1)
    return nothing
end

"The published originals the app can check for replies, with the account that posted them."
function watched_posts(app::CommunityApp)
    s = app.state[]
    archived = Set(p.id for p in s.projects if p.state == "archived")
    out = Tuple{Draft,Post,Account}[]
    for d in s.drafts
        d.status == "published" && !(d.project in archived) && publishes(find_platform(d.platform)) || continue
        (isempty(d.posts) || isempty(d.posts[1].account)) && continue  # posted by hand: nothing to check
        i = findfirst(a -> a.id == d.posts[1].account, s.accounts)
        i === nothing || push!(out, (d, d.posts[1], s.accounts[i]))
    end
    return out
end

"""
    check_replies!(app, d, post, account) -> Int

Fetch the replies to `post` and keep the new ones (not from the app's own
accounts). Returns how many were new.
"""
function check_replies!(app::CommunityApp, d::Draft, post::Post, a::Account)
    found = fetch_replies(find_platform(d.platform), app, a, post)
    lock(() -> (app.polled[d.id] = now(UTC)), app.lock)
    ours = Set(lowercase(x.handle) for x in app.state[].accounts)
    local added
    update!(app) do s
        known = Set(r.ref for r in s.replies)
        new = [Reply(r.ref, r.cid, d.project, d.id, d.platform, a.id, r.author, r.author_name, r.text, r.url,
                     r.created, "new", "")
               for r in found if !(r.ref in known) && !(lowercase(r.author) in ours)]
        added = length(new)
        with(s; replies = vcat(s.replies, new))
    end
    return added
end

"Keep the latest counts on the draft's original post."
function update_stats!(app::CommunityApp, id::Int, stats::Dict{String,Int})
    d = find_draft(app, id)
    isempty(d.posts) && return d
    o = d.posts[1]
    original = Post(o.account, o.kind, o.ref, o.cid, o.url, o.at, stats)
    return set_draft!(app, id; posts = vcat(original, d.posts[2:end]))
end

"Totals over drafts: views, likes, reposts, replies of their original posts."
function stats_total(drafts)
    total = Dict("views" => 0, "likes" => 0, "reposts" => 0, "replies" => 0)
    for d in drafts, (k, v) in (isempty(d.posts) ? Dict{String,Int}() : d.posts[1].stats)
        total[k] = get(total, k, 0) + v
    end
    return total
end

"Check every watched post that is due; what failed, as messages. Each check runs on its own: one failing doesn't stop the rest."
function poll_replies!(app::CommunityApp)
    # A periodic task must never unlock credentials. A manual, PIN-authorised
    # action can add a dedicated refresh later; until then this is deliberately
    # silent while locked.
    vault_active(app) || return String[]
    t = now(UTC)
    problems = String[]
    for (d, post, a) in watched_posts(app)
        every = check_interval(post.at, t)
        every === nothing && continue
        last = lock(() -> get(app.polled, d.id, nothing), app.lock)
        last === nothing || t - last >= every || continue
        r = attempt(() -> check_replies!(app, d, post, a), "checking replies to draft #$(d.id)")
        r isa Int || push!(problems, "draft #$(d.id): $r")
        s = attempt(() -> update_stats!(app, d.id, fetch_stats(find_platform(d.platform), app, a, post)),
                    "counting the reactions to draft #$(d.id)")
        s isa Draft || push!(problems, "stats of draft #$(d.id): $s")
    end
    return problems
end

"One round of the background checks: the replies to the projects' posts, then the inbox."
function poll!(app::CommunityApp)
    problems = vcat(poll_replies!(app), poll_inbox!(app))
    app.notice[] = isempty(problems) ? "" : "Checking failed for " * join(problems, "; ")
    return nothing
end

"Fetch post statistics, replies and mentions during one explicit PIN-authorised action."
poll_with_pin!(app::CommunityApp, pin::AbstractString) = with_vault!(() -> poll!(app), app, pin)

function start_polling!(app::CommunityApp)
    app.poller = Timer(_ -> poll!(app), 20; interval = 60)
    return app
end

# ── answers ─────────────────────────────────────────────────────────────────

function reply_index(s::CommunityFile, ref::AbstractString)
    i = findfirst(r -> r.ref == ref, s.replies)
    i === nothing && throw(AppError("there is no reply '$ref'"))
    return i
end
find_reply(app::CommunityApp, ref::AbstractString) = (s = app.state[]; s.replies[reply_index(s, ref)])

function set_reply!(app::CommunityApp, ref::AbstractString; kw...)
    haskey(kw, :status) && !(kw[:status] in REPLY_STATES) && throw(AppError("unknown reply status '$(kw[:status])'"))
    local r
    update!(app) do s
        replies = copy(s.replies)
        i = reply_index(s, ref)
        r = replies[i] = change(replies[i]; kw...)
        with(s; replies)
    end
    return r
end

"Draft the answer to a reply: checked against the platform's limit, sent only with a click."
function draft_answer!(app::CommunityApp, ref::AbstractString, text::AbstractString)
    r = find_reply(app, ref)
    r.status == "answered" && throw(AppError("that reply is already answered"))
    t = strip(text)
    isempty(t) && throw(AppError("an answer needs a text"))
    check_draft_text(find_platform(r.platform), "", t)
    return set_reply!(app, ref; answer = t, status = "drafted")
end

"Send the drafted answer, from the account whose post was replied to."
function send_answer!(app::CommunityApp, ref::AbstractString)
    r = find_reply(app, ref)
    r.status == "drafted" || throw(AppError("draft an answer first"))
    root = find_draft(app, r.draft).posts[1]
    to = AnswerTo(root.ref, root.cid, r.ref, r.cid, r.author)
    send_answer(find_platform(r.platform), app, find_account(app, r.account), to, r.answer)
    return set_reply!(app, ref; status = "answered")
end

function send_in_background!(app::CommunityApp, ref::AbstractString)
    throw(AppError("sending an answer needs an explicit PIN-authorised dashboard action"))
end

function send_answer_with_pin!(app::CommunityApp, ref::AbstractString, pin::AbstractString)
    find_reply(app, ref).status == "drafted" || throw(AppError("draft an answer first"))
    return with_vault!(app, pin) do
        send_answer!(app, ref)
    end
end
