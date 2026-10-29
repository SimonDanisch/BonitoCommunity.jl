# Facebook Page and Instagram (Meta Graph API) with one long-lived Page access
# token, pasted: it is the Page's, and finds the Instagram account linked to it.
# Facebook videos go up in chunks (start, transfer, finish); an Instagram Reel
# is uploaded resumably, processed, then published. Comments are the replies.

const GRAPH = "https://graph.facebook.com/v23.0"
const GRAPH_VIDEO = "https://graph-video.facebook.com/v23.0"
const RUPLOAD = "https://rupload.facebook.com/ig-api-upload/v23.0"

publishes(::Facebook) = true
publishes(::Instagram) = true
reposts(::Facebook) = false
reposts(::Instagram) = false

graph(method, path; token, query = Pair{String,String}[], kw...) =
    api(method, (startswith(path, "http") ? path : GRAPH * path); query = vcat(query, "access_token" => token), kw...)

"""
    add_meta_accounts!(app, brand, page_token) -> Vector{Account}

The Page the token belongs to, and the Instagram account linked to that Page,
as `brand`'s Facebook and Instagram accounts. The token is checked first.
"""
function add_meta_accounts!(app::CommunityApp, brand::AbstractString, token::AbstractString)
    b = find_brand(app, brand)
    t = strip(token)
    isempty(t) && throw(AppError("paste the Page's access token"))
    page = graph("GET", "/me"; token = t, query = ["fields" => "id,name"])
    added = Account[]
    if "facebook" in b.platforms
        push!(added, Account("facebook:" * string(page["id"]), "facebook", b.name, string(page["name"]),
                             "https://www.facebook.com/" * string(page["id"]), "post"))
    end
    ig = get(graph("GET", "/" * string(page["id"]); token = t, query = ["fields" => "instagram_business_account{id,username}"]),
             "instagram_business_account", nothing)
    if ig !== nothing && "instagram" in b.platforms
        push!(added, Account("instagram:" * string(ig["id"]), "instagram", b.name, string(ig["username"]),
                             "https://www.instagram.com/" * string(ig["username"]), "post"))
    end
    isempty(added) && throw(AppError("$(b.name) posts on neither Facebook nor Instagram, or the Page has no Instagram account"))
    for a in added
        store_secret!(app, a.id, t)
    end
    ids = Set(a.id for a in added)
    update!(s -> with(s; accounts = vcat(filter(x -> !(x.id in ids), s.accounts), added)), app)
    return added
end

function add_meta_accounts_with_pin!(app::CommunityApp, brand::AbstractString, token::AbstractString, pin::AbstractString)
    vault_exists(app) || throw(AppError("set a Community PIN before adding Facebook or Instagram"))
    return with_vault!(app, pin) do
        add_meta_accounts!(app, brand, token)
    end
end

account_object(a::Account) = split(a.id, ':'; limit = 2)[2]      # the Page's or Instagram account's id

# ── multipart, written out: Graph's video uploads take form fields and a file chunk ─

function multipart(fields::Vector{Pair{String,String}}, file::Union{Nothing,Pair{String,Vector{UInt8}}} = nothing)
    boundary = "----community-" * pkce_verifier()[1:24]
    io = IOBuffer()
    for (k, v) in fields
        write(io, "--$boundary\r\nContent-Disposition: form-data; name=\"$k\"\r\n\r\n$v\r\n")
    end
    if file !== nothing
        write(io, "--$boundary\r\nContent-Disposition: form-data; name=\"$(file[1])\"; filename=\"chunk\"\r\n",
              "Content-Type: application/octet-stream\r\n\r\n")
        write(io, file[2])
        write(io, "\r\n")
    end
    write(io, "--$boundary--\r\n")
    return take!(io), "multipart/form-data; boundary=$boundary"
end

function media_file(app::CommunityApp, d::Draft)
    isempty(d.media) && return nothing
    file = joinpath(project_folder(projects_dir(app), find_project(app, d.project)), d.media[1])
    is_video(file) && isfile(file) || throw(AppError("$(d.media[1]) is not a video in the project folder"))
    return file
end

# ── Facebook ────────────────────────────────────────────────────────────────

verify_account(::Facebook, ::Account, ::AbstractString) =
    throw(AppError("Facebook and Instagram are added together, with the Page's access token"))
verify_account(::Instagram, ::Account, ::AbstractString) =
    throw(AppError("Facebook and Instagram are added together, with the Page's access token"))

"Upload `file` to the Page in chunks; returns the video's id."
function facebook_video(endpoint::AbstractString, token::AbstractString, file::AbstractString,
                        title::AbstractString, description::AbstractString)
    size = filesize(file)
    form(fields...) = multipart(["access_token" => token, fields...])
    body, ct = form("upload_phase" => "start", "file_size" => string(size))
    s = api("POST", endpoint; body, content_type = ct)
    session, video = string(s["upload_session_id"]), string(s["video_id"])
    from, to = parse(Int, string(s["start_offset"])), parse(Int, string(s["end_offset"]))
    open(file) do io
        while from < to
            seek(io, from)
            chunk = read(io, to - from)
            body, ct = multipart(["access_token" => token, "upload_phase" => "transfer", "upload_session_id" => session,
                                  "start_offset" => string(from)], "video_file_chunk" => chunk)
            r = api("POST", endpoint; body, content_type = ct)
            from, to = parse(Int, string(r["start_offset"])), parse(Int, string(r["end_offset"]))
        end
    end
    body, ct = form("upload_phase" => "finish", "upload_session_id" => session, "title" => title, "description" => description)
    api("POST", endpoint; body, content_type = ct)
    return video
end

function publish(::Facebook, app::CommunityApp, a::Account, d::Draft, text::AbstractString)
    page, token = account_object(a), secret(app, a)
    file = media_file(app, d)
    if file === nothing
        r = graph("POST", "/$page/feed"; token, query = ["message" => text])
        return Post(a.id, "original", string(r["id"]), "", "https://www.facebook.com/" * string(r["id"]), now(UTC))
    end
    video = facebook_video("$GRAPH_VIDEO/$page/videos", token, file, d.title, text)
    return Post(a.id, "original", video, "", "https://www.facebook.com/$page/videos/$video", now(UTC))
end

# ── Instagram ───────────────────────────────────────────────────────────────

"Send `file` to an Instagram upload container, streamed."
function rupload(uri::AbstractString, token::AbstractString, file::AbstractString)
    r = open(file) do io
        HTTP.request("POST", uri, ["Authorization" => "OAuth $token", "offset" => "0",
                                   "file_size" => string(filesize(file))], io;
                     status_exception = false, retry = false, request_timeout = 900)
    end
    r.status == 200 || throw(AppError("the Instagram upload failed ($(r.status)): $(api_error_text(r.body))"))
    return nothing
end

function publish(::Instagram, app::CommunityApp, a::Account, d::Draft, text::AbstractString)
    ig, token = account_object(a), secret(app, a)
    file = media_file(app, d)
    file === nothing && throw(AppError("an Instagram draft needs its video (a Reel)"))
    c = graph("POST", "/$ig/media"; token, query = ["media_type" => "REELS", "upload_type" => "resumable",
                                                     "caption" => text, "share_to_feed" => "true"])
    container = string(c["id"])
    rupload(get(c, "uri", "$RUPLOAD/$container"), token, file)
    # Instagram processes the video before it can be published
    for _ in 1:120
        st = string(graph("GET", "/$container"; token, query = ["fields" => "status_code"])["status_code"])
        st == "FINISHED" && break
        st == "ERROR" && throw(AppError("Instagram could not process the video"))
        set_draft!(app, d.id; note = "Instagram is processing the video…")
        sleep(5)
    end
    m = graph("POST", "/$ig/media_publish"; token, query = ["creation_id" => container])
    link = graph("GET", "/" * string(m["id"]); token, query = ["fields" => "permalink"])
    return Post(a.id, "original", string(m["id"]), "", string(link["permalink"]), now(UTC))
end

# ── comments ────────────────────────────────────────────────────────────────

function fetch_replies(::Facebook, app::CommunityApp, a::Account, post::Post)
    r = graph("GET", "/$(post.ref)/comments"; token = secret(app, a),
              query = ["fields" => "id,message,from,created_time,permalink_url", "limit" => "100"])
    return [(ref = string(c["id"]), cid = "", author = string(get(get(c, "from", Dict()), "name", "someone")),
             author_name = string(get(get(c, "from", Dict()), "name", "someone")), text = string(get(c, "message", "")),
             url = string(get(c, "permalink_url", post.url)), created = parse_time(string(c["created_time"])))
            for c in r["data"]]
end

function fetch_replies(::Instagram, app::CommunityApp, a::Account, post::Post)
    r = graph("GET", "/$(post.ref)/comments"; token = secret(app, a),
              query = ["fields" => "id,text,username,timestamp", "limit" => "100"])
    return [(ref = string(c["id"]), cid = "", author = string(c["username"]), author_name = string(c["username"]),
             text = string(c["text"]), url = post.url, created = parse_time(string(c["timestamp"])))
            for c in r["data"]]
end

send_answer(::Facebook, app::CommunityApp, a::Account, to::AnswerTo, text::AbstractString) =
    (graph("POST", "/$(to.post)/comments"; token = secret(app, a), query = ["message" => text]); nothing)
send_answer(::Instagram, app::CommunityApp, a::Account, to::AnswerTo, text::AbstractString) =
    (graph("POST", "/$(to.post)/replies"; token = secret(app, a), query = ["message" => text]); nothing)

function fetch_stats(::Facebook, app::CommunityApp, a::Account, post::Post)
    r = graph("GET", "/$(post.ref)"; token = secret(app, a),
              query = ["fields" => "likes.summary(true).limit(0),comments.summary(true).limit(0)"])
    total(k) = Int(get(get(get(r, k, Dict()), "summary", Dict()), "total_count", 0))
    return Dict("likes" => total("likes"), "replies" => total("comments"))
end

function fetch_stats(::Instagram, app::CommunityApp, a::Account, post::Post)
    r = graph("GET", "/$(post.ref)"; token = secret(app, a), query = ["fields" => "like_count,comments_count"])
    return Dict("likes" => Int(get(r, "like_count", 0)), "replies" => Int(get(r, "comments_count", 0)))
end
