# Bluesky (AT Protocol): app-password sessions, posts with rich-text facets and
# a link card, reposts, and the replies in a post's thread.

const BSKY_SERVER = "https://bsky.social"

account_server(::Bluesky, ::AbstractString, server::AbstractString) =
    isempty(server) ? BSKY_SERVER : rstrip(startswith(server, "http") ? server : "https://" * server, '/')

bsky_login(server::AbstractString, handle::AbstractString, password::AbstractString) =
    (r = api("POST", "$server/xrpc/com.atproto.server.createSession";
             json = Dict("identifier" => handle, "password" => password));
     Session(r["accessJwt"], r["did"], now(UTC)))

verify_account(::Bluesky, a::Account, secret::AbstractString) = (bsky_login(a.server, a.handle, secret); nothing)

# A logged-in session for `a`, kept for 90 minutes (the token lives about two hours).
function session(app::CommunityApp, a::Account)
    s = lock(() -> get(app.sessions, a.id, nothing), app.lock)
    if s === nothing || now(UTC) - s.at > Minute(90)
        s = bsky_login(a.server, a.handle, secret(app, a))
        lock(() -> (app.sessions[a.id] = s), app.lock)
    end
    return s
end

# ── rich text ───────────────────────────────────────────────────────────────

const BSKY_URL = r"https?://[^\s<>\"]*[^\s<>\".,;:!?)\]'\"]"
const BSKY_TAG = r"(?<![\w#/&])#([\p{L}\p{N}_]*\p{L}[\p{L}\p{N}_]*)"
const BSKY_MENTION = r"(?<![\w@])@([a-zA-Z0-9][a-zA-Z0-9-]*(?:\.[a-zA-Z0-9-]+)+)"

# A facet over the byte range of match `m` (Bluesky indexes UTF-8 bytes, from 0).
bsky_facet(m::RegexMatch, feature::Dict) =
    Dict("index" => Dict("byteStart" => m.offset - 1, "byteEnd" => m.offset - 1 + ncodeunits(m.match)),
         "features" => [feature])

overlaps(f, g) = f["index"]["byteStart"] < g["index"]["byteEnd"] && g["index"]["byteStart"] < f["index"]["byteEnd"]

"""
    bsky_facets(text; resolve) -> Vector

Links, hashtags and mentions in `text` as Bluesky facets. `resolve(handle)`
gives a handle's DID, or `nothing` for one that doesn't exist (left as text).
"""
function bsky_facets(text::AbstractString; resolve)
    links = [bsky_facet(m, Dict("\$type" => "app.bsky.richtext.facet#link", "uri" => m.match))
             for m in eachmatch(BSKY_URL, text)]
    tags = [bsky_facet(m, Dict("\$type" => "app.bsky.richtext.facet#tag", "tag" => m.captures[1]))
            for m in eachmatch(BSKY_TAG, text)]
    mentions = Dict[]
    for m in eachmatch(BSKY_MENTION, text)
        did = resolve(m.captures[1])
        did === nothing || push!(mentions, bsky_facet(m, Dict("\$type" => "app.bsky.richtext.facet#mention", "did" => did)))
    end
    rest = filter(f -> !any(l -> overlaps(f, l), links), vcat(tags, mentions))
    return sort!(vcat(links, rest); by = f -> f["index"]["byteStart"])
end

function bsky_resolve(server::AbstractString, handle::AbstractString)
    r = HTTP.request("GET", "$server/xrpc/com.atproto.identity.resolveHandle"; query = ["handle" => handle],
                     status_exception = false, retry = false, connect_timeout = 15, request_timeout = 30)
    r.status == 200 || return nothing
    return JSON.parse(String(r.body))["did"]
end

# ── link card ───────────────────────────────────────────────────────────────

"Title, description and picture of a page, for its link card: YouTube's oEmbed, else the page's Open Graph tags."
function link_meta(url::AbstractString)
    if occursin(r"^https://(www\.)?(youtube\.com|youtu\.be)/", url)
        r = api("GET", "https://www.youtube.com/oembed"; query = ["url" => url, "format" => "json"])
        return (title = string(r["title"]), description = "YouTube video by $(r["author_name"])",
                image = string(r["thumbnail_url"]))
    end
    r = HTTP.request("GET", url; status_exception = false, retry = false, connect_timeout = 15, request_timeout = 30)
    r.status == 200 || return (title = url, description = "", image = "")
    html = String(r.body)
    og(name) = (m = match(Regex("<meta[^>]+property=\"og:$name\"[^>]+content=\"([^\"]*)\"", "i"), html);
                m === nothing ? "" : html_text(m.captures[1]))
    title = og("title")
    return (title = isempty(title) ? String(url) : title, description = og("description"), image = og("image"))
end

function upload_blob(a::Account, s::Session, bytes::Vector{UInt8}, content_type::AbstractString)
    length(bytes) > 1_000_000 && throw(AppError("a picture for Bluesky must be under 1 MB"))
    return api("POST", "$(a.server)/xrpc/com.atproto.repo.uploadBlob"; token = s.access, body = bytes,
               content_type)["blob"]
end

function link_card(a::Account, s::Session, url::AbstractString)
    meta = link_meta(url)
    external = Dict{String,Any}("uri" => url, "title" => meta.title, "description" => meta.description)
    isempty(meta.image) || (external["thumb"] = upload_blob(a, s, fetch_bytes(meta.image)...))
    return Dict("\$type" => "app.bsky.embed.external", "external" => external)
end

# ── posting ─────────────────────────────────────────────────────────────────

bsky_web_url(handle::AbstractString, uri::AbstractString) = "https://bsky.app/profile/$handle/post/$(last(split(uri, '/')))"

function bsky_create(a::Account, s::Session, collection::AbstractString, record::Dict)
    return api("POST", "$(a.server)/xrpc/com.atproto.repo.createRecord"; token = s.access,
               json = Dict("repo" => s.did, "collection" => collection, "record" => record))
end

function bsky_post_record(a::Account, s::Session, text::AbstractString; reply = nothing, card::Bool = true)
    record = Dict{String,Any}("\$type" => "app.bsky.feed.post", "text" => text,
                              "createdAt" => iso(now(UTC)), "langs" => ["en"])
    facets = bsky_facets(text; resolve = h -> bsky_resolve(a.server, h))
    isempty(facets) || (record["facets"] = facets)
    link = findfirst(f -> f["features"][1]["\$type"] == "app.bsky.richtext.facet#link", facets)
    card && link !== nothing && (record["embed"] = link_card(a, s, facets[link]["features"][1]["uri"]))
    reply === nothing || (record["reply"] = reply)
    return record
end

function publish(::Bluesky, app::CommunityApp, a::Account, ::Draft, text::AbstractString)
    s = session(app, a)
    r = bsky_create(a, s, "app.bsky.feed.post", bsky_post_record(a, s, text))
    return Post(a.id, "original", r["uri"], r["cid"], bsky_web_url(a.handle, r["uri"]), now(UTC))
end

function repost(::Bluesky, app::CommunityApp, a::Account, original::Post)
    s = session(app, a)
    r = bsky_create(a, s, "app.bsky.feed.repost",
                    Dict("\$type" => "app.bsky.feed.repost", "createdAt" => iso(now(UTC)),
                         "subject" => Dict("uri" => original.ref, "cid" => original.cid)))
    return Post(a.id, "repost", r["uri"], r["cid"], original.url, now(UTC))
end

function fetch_stats(::Bluesky, app::CommunityApp, a::Account, post::Post)
    r = api("GET", "$(a.server)/xrpc/app.bsky.feed.getPosts"; token = session(app, a).access, query = ["uris" => post.ref])
    isempty(r["posts"]) && return Dict{String,Int}()
    p = r["posts"][1]
    return Dict("likes" => Int(get(p, "likeCount", 0)), "reposts" => Int(get(p, "repostCount", 0)) + Int(get(p, "quoteCount", 0)),
                "replies" => Int(get(p, "replyCount", 0)))
end

# ── replies ─────────────────────────────────────────────────────────────────

function fetch_replies(::Bluesky, app::CommunityApp, a::Account, post::Post)
    s = session(app, a)
    r = api("GET", "$(a.server)/xrpc/app.bsky.feed.getPostThread"; token = s.access,
            query = ["uri" => post.ref, "depth" => "10", "parentHeight" => "0"])
    out = NamedTuple[]
    collect_replies!(out, r["thread"])
    return out
end

# Every post below `node` in the thread, depth first; blocked and deleted ones have no `post`.
function collect_replies!(out, node)
    for child in get(node, "replies", [])
        haskey(child, "post") || continue
        p = child["post"]
        author = p["author"]
        push!(out, (ref = string(p["uri"]), cid = string(p["cid"]), author = string(author["handle"]),
                    author_name = string(get(author, "displayName", author["handle"])),
                    text = string(p["record"]["text"]), url = bsky_web_url(author["handle"], p["uri"]),
                    created = parse_time(string(p["record"]["createdAt"]))))
        collect_replies!(out, child)
    end
    return out
end

function send_answer(::Bluesky, app::CommunityApp, a::Account, to::AnswerTo, text::AbstractString)
    s = session(app, a)
    thread = Dict("root" => Dict("uri" => to.root, "cid" => to.root_cid),
                  "parent" => Dict("uri" => to.post, "cid" => to.post_cid))
    bsky_create(a, s, "app.bsky.feed.post", bsky_post_record(a, s, text; reply = thread, card = false))
    return nothing
end

# ── mentions ────────────────────────────────────────────────────────────────

"Mentions, replies and quotes of `a` (its notifications), with the thread each is in."
function fetch_mentions(::Bluesky, app::CommunityApp, a::Account)
    s = session(app, a)
    r = api("GET", "$(a.server)/xrpc/app.bsky.notification.listNotifications"; token = s.access, query = ["limit" => "50"])
    out = NamedTuple[]
    for n in r["notifications"]
        n["reason"] in ("mention", "reply", "quote") || continue
        rec = n["record"]
        thread = get(rec, "reply", nothing)
        uri, cid = string(n["uri"]), string(n["cid"])
        root, root_cid = thread === nothing ? (uri, cid) : (string(thread["root"]["uri"]), string(thread["root"]["cid"]))
        author = n["author"]
        push!(out, (post = uri, post_cid = cid, root, root_cid, parent = thread === nothing ? "" : string(thread["parent"]["uri"]),
                    author = string(author["handle"]), author_name = string(get(author, "displayName", author["handle"])),
                    text = string(get(rec, "text", "")), url = bsky_web_url(author["handle"], uri),
                    created = parse_time(string(rec["createdAt"]))))
    end
    return out
end
