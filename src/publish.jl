# Publishing an approved draft: the brand's account posts it, the other accounts
# repost it, the project moves on. Platforms the app doesn't publish to are
# posted by hand; their link is pasted back (`mark_published!`).

"""
    publish_draft!(app, id) -> Draft

Publish approved draft `id` with its brand's account, then repost it with the
amplifying accounts. A failed repost is noted on the draft, which stays
published; a failed post leaves the draft `failed` with the reason.
"""
function publish_draft!(app::CommunityApp, id::Int)
    d = find_draft(app, id)
    d.status in ("approved", "publishing") || throw(AppError("draft #$id is $(d.status); only approved drafts are published"))
    pl = find_platform(d.platform)
    publishes(pl) || throw(AppError("$(platform_name(pl)) is posted by hand: post it there, then paste the link"))
    p = find_project(app, d.project)
    origin = posting_account(app, d.brand, d.platform)
    text = fill_links(d.text, p)
    original = publish(pl, app, origin, d, text)
    d = set_draft!(app, id; status = "published", note = "", posts = [original])
    # the project's video: what its link posts point to
    d.platform == "youtube" && d.kind == "video" && !haskey(p.links, "youtube") && set_link!(app, p.id, "youtube", original.url)
    failed = String[]
    for a in (reposts(pl) ? amplifying_accounts(app, origin, p) : Account[])
        r = attempt(() -> repost(pl, app, a, original), "repost of draft #$id by $(a.handle)")
        r isa Post ? (d = set_draft!(app, id; posts = vcat(find_draft(app, id).posts, r))) : push!(failed, "$(a.handle): $r")
    end
    isempty(failed) || (d = set_draft!(app, id; note = "reposts failed: " * join(failed, "; ")))
    advance_project!(app, p.id)
    return d
end

"A draft posted by hand: its link, as the original post. A YouTube video's link becomes the project's."
function mark_published!(app::CommunityApp, id::Int, url::AbstractString)
    d = find_draft(app, id)
    d.status in ("approved", "draft", "changes", "failed") || throw(AppError("draft #$id is already published"))
    u = strip(url)
    startswith(u, "https://") || throw(AppError("paste the post's link (https://...)"))
    d = set_draft!(app, id; status = "published", note = "", posts = [Post("", "original", "", "", u, now(UTC))])
    p = find_project(app, d.project)
    d.platform == "youtube" && d.kind == "video" && !haskey(p.links, "youtube") && set_link!(app, p.id, "youtube", u)
    advance_project!(app, p.id)
    return d
end

"Publishing moves a project on: to `publishing` with its first post, to `community` once every draft is out."
function advance_project!(app::CommunityApp, id::AbstractString)
    p = find_project(app, id)
    drafts = project_drafts(app.state[], id)
    any(d -> d.status == "published", drafts) || return p
    rank = findfirst(==(p.state), PROJECT_STATES)
    target = all(d -> d.status == "published", drafts) ? "community" : "publishing"
    findfirst(==(target), PROJECT_STATES) > rank || return p
    return set_project!(app, id; state = target)
end

"""
    attempt(f, what) -> value or message

Run `f`; when it throws, log the error with what was being done and return its
message instead. For work the user is not waiting on in a call stack: the
publishing task, the reply checks.
"""
function attempt(f, what::AbstractString)
    try
        return f()
    catch e
        e isa InterruptException && rethrow()
        @error "community: $what failed" exception = (e, catch_backtrace())
        return e isa AppError ? e.msg : sprint(showerror, e)
    end
end

"""
    publish_in_background!(app, id)

Claim approved draft `id` (`publishing`, so a second click can't post it twice)
and publish it in a task: a click shouldn't wait on the network. A failure ends
up on the draft.
"""
function publish_in_background!(app::CommunityApp, id::Int)
    throw(AppError("publishing needs an explicit PIN-authorised dashboard action"))
end

"Publish one approved draft while credentials are leased for this call only."
function publish_with_pin!(app::CommunityApp, id::Int, pin::AbstractString)
    claimed = false
    try
        return with_vault!(app, pin) do
            update!(app) do s
                drafts = copy(s.drafts)
                i = draft_index(s, id)
                d = drafts[i]
                d.status == "approved" || throw(AppError("draft #$id is $(d.status); only approved drafts are published"))
                publishes(find_platform(d.platform)) || throw(AppError("$(d.platform) is posted by hand"))
                drafts[i] = change(d; status = "publishing", note = "", updated = now(UTC))
                with(s; drafts)
            end
            claimed = true
            publish_draft!(app, id)
        end
    catch e
        claimed && find_draft(app, id).status != "published" &&
            set_draft!(app, id; status = "failed", note = e isa AppError ? e.msg : sprint(showerror, e))
        rethrow()
    end
end

"The approved dashboard-postable drafts of one project, in dependency order."
function publishable_drafts(app::CommunityApp, project_id::AbstractString)
    drafts = filter(d -> d.project == project_id && d.status == "approved" && publishes(find_platform(d.platform)), app.state[].drafts)
    isempty(drafts) && throw(AppError("there are no approved automatic posts for this release"))
    # Link posts can depend on the video's URL, which its upload supplies.
    sort!(drafts; by = d -> d.platform == "youtube" ? 0 : 1)
    has_youtube = any(d -> d.platform == "youtube" && d.kind == "video", drafts)
    for d in drafts
        p = find_project(app, d.project)
        missing = missing_links(d.text, p)
        filter!(x -> !(x == "youtube" && has_youtube), missing)
        isempty(missing) || throw(AppError("draft #$(d.id) needs the project's $(join(missing, " and ")) link before this release can be sent"))
        posting_account(app, d.brand, d.platform)
    end
    return drafts
end

"Publish every approved automatic post for a release under one explicit PIN lease."
function publish_approved_with_pin!(app::CommunityApp, project_id::AbstractString, pin::AbstractString)
    targets = publishable_drafts(app, project_id) # validate the whole release before sending any post
    return with_vault!(app, pin) do
        result = Draft[]
        for target in targets
            id = target.id
            update!(app) do s
                drafts = copy(s.drafts)
                i = draft_index(s, id)
                d = drafts[i]
                d.status == "approved" || throw(AppError("draft #$id changed while this release was being sent"))
                drafts[i] = change(d; status = "publishing", note = "", updated = now(UTC))
                with(s; drafts)
            end
            try
                push!(result, publish_draft!(app, id))
            catch e
                set_draft!(app, id; status = "failed", note = e isa AppError ? e.msg : sprint(showerror, e))
                push!(result, find_draft(app, id))
            end
        end
        result
    end
end
