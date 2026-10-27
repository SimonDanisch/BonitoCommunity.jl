# Mastodon: an access token per account (Preferences → Development, scopes
# read and write), statuses, boosts and the replies below a status.

function account_server(::Mastodon, handle::AbstractString, server::AbstractString)
    isempty(server) || return rstrip(startswith(server, "http") ? server : "https://" * server, '/')
    parts = split(handle, '@')
    length(parts) == 2 || throw(AppError("a Mastodon handle is user@server, e.g. makie@fosstodon.org"))
    return "https://" * parts[2]
end

verify_account(::Mastodon, a::Account, secret::AbstractString) =
    (api("GET", "$(a.server)/api/v1/accounts/verify_credentials"; token = secret); nothing)

function publish(::Mastodon, app::CommunityApp, a::Account, ::Draft, text::AbstractString)
    r = api("POST", "$(a.server)/api/v1/statuses"; token = secret(app, a),
            json = Dict("status" => text, "visibility" => "public", "language" => "en"),
            headers = ["Idempotency-Key" => string(hash((a.id, text)))])
    return Post(a.id, "original", string(r["id"]), "", string(r["url"]), now(UTC))
end

# The status as `a`'s server knows it: another server's status has to be looked up there first.
function local_status_id(app::CommunityApp, a::Account, url::AbstractString)
    r = api("GET", "$(a.server)/api/v2/search"; token = secret(app, a),
            query = ["q" => url, "resolve" => "true", "type" => "statuses", "limit" => "1"])
    isempty(r["statuses"]) && throw(AppError("$(a.server) can't find $url"))
    return string(r["statuses"][1]["id"])
end

function repost(::Mastodon, app::CommunityApp, a::Account, original::Post)
    id = local_status_id(app, a, original.url)
    r = api("POST", "$(a.server)/api/v1/statuses/$id/reblog"; token = secret(app, a))
    return Post(a.id, "repost", string(r["id"]), "", original.url, now(UTC))
end

function fetch_stats(::Mastodon, app::CommunityApp, a::Account, post::Post)
    s = api("GET", "$(a.server)/api/v1/statuses/$(post.ref)"; token = secret(app, a))
    return Dict("likes" => Int(s["favourites_count"]), "reposts" => Int(s["reblogs_count"]), "replies" => Int(s["replies_count"]))
end

function fetch_replies(::Mastodon, app::CommunityApp, a::Account, post::Post)
    r = api("GET", "$(a.server)/api/v1/statuses/$(post.ref)/context"; token = secret(app, a))
    return [(ref = string(s["id"]), cid = "", author = string(s["account"]["acct"]),
             author_name = string(isempty(s["account"]["display_name"]) ? s["account"]["acct"] : s["account"]["display_name"]),
             text = html_text(string(s["content"])), url = string(something(s["url"], s["uri"])),
             created = parse_time(string(s["created_at"])))
            for s in r["descendants"]]
end

function send_answer(::Mastodon, app::CommunityApp, a::Account, to::AnswerTo, text::AbstractString)
    # Mastodon notifies whom a status mentions: the answer starts with the author.
    mention = "@" * to.author
    status = startswith(text, mention) ? text : mention * " " * text
    api("POST", "$(a.server)/api/v1/statuses"; token = secret(app, a),
        json = Dict("status" => status, "in_reply_to_id" => to.post, "visibility" => "public", "language" => "en"))
    return nothing
end

"The statuses that mention `a` (its mention notifications); `parent` is what each answers, if anything."
function fetch_mentions(::Mastodon, app::CommunityApp, a::Account)
    r = api("GET", "$(a.server)/api/v1/notifications"; token = secret(app, a),
            query = ["types[]" => "mention", "limit" => "40"])
    out = NamedTuple[]
    for n in r
        st = n["status"]
        st === nothing && continue
        acc = st["account"]
        push!(out, (post = string(st["id"]), post_cid = "", root = "", root_cid = "",
                    parent = string(something(st["in_reply_to_id"], "")), author = string(acc["acct"]),
                    author_name = string(isempty(acc["display_name"]) ? acc["acct"] : acc["display_name"]),
                    text = html_text(string(st["content"])), url = string(something(st["url"], st["uri"])),
                    created = parse_time(string(st["created_at"]))))
    end
    return out
end
