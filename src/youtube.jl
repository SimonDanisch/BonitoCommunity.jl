# YouTube (Data API v3): a Google login per channel (OAuth for installed apps,
# with PKCE and a one-off callback on 127.0.0.1), resumable uploads, and the
# comments under a video as the project's replies.
#
# The OAuth client is a "Desktop app" client of the user's Google Cloud project
# (YouTube Data API v3 enabled). Until Google has audited that project, what it
# uploads stays private (`Settings.youtube_privacy`).

const GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token"
const YT_API = "https://www.googleapis.com/youtube/v3"
const YT_UPLOAD = "https://www.googleapis.com/upload/youtube/v3/videos"
const YT_SCOPES = "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.force-ssl"
const YT_CHUNK = 32 * 1024 * 1024           # a multiple of 256 KiB, as resumable uploads want
const YT_SCIENCE_AND_TECHNOLOGY = "28"

google_client(app::CommunityApp) = (s = load_secrets(app); (get(s, "google:client_id", ""), get(s, "google:client_secret", "")))

function set_google_client!(app::CommunityApp, id::AbstractString, secret_::AbstractString)
    (isempty(strip(id)) || isempty(strip(secret_))) && throw(AppError("the OAuth client needs its id and its secret"))
    endswith(strip(id), ".apps.googleusercontent.com") || throw(AppError("that is not a Google OAuth client id"))
    store_secret!(app, "google:client_id", strip(id))
    store_secret!(app, "google:client_secret", strip(secret_))
    return nothing
end

form(pairs...) = Vector{UInt8}(HTTP.escapeuri(Dict(pairs)))

"A fresh access token for `a`'s channel, from its refresh token; kept for 50 minutes (they live an hour)."
function google_access(app::CommunityApp, a::Account)
    s = lock(() -> get(app.sessions, a.id, nothing), app.lock)
    s === nothing || now(UTC) - s.at > Minute(50) || return s.access
    id, client_secret = google_client(app)
    r = api("POST", GOOGLE_TOKEN; content_type = "application/x-www-form-urlencoded",
            body = form("client_id" => id, "client_secret" => client_secret, "refresh_token" => secret(app, a),
                        "grant_type" => "refresh_token"))
    lock(() -> (app.sessions[a.id] = Session(r["access_token"], "", now(UTC))), app.lock)
    return string(r["access_token"])
end

# ── logging in ──────────────────────────────────────────────────────────────

const URLSAFE = ['A':'Z'; 'a':'z'; '0':'9'; '-'; '.'; '_'; '~']
pkce_verifier() = String(rand(URLSAFE, 64))
pkce_challenge(verifier::AbstractString) =
    rstrip(replace(base64encode(SHA.sha256(verifier)), '+' => '-', '/' => '_'), '=')

function consent_url(client_id::AbstractString, redirect::AbstractString, challenge::AbstractString, state::AbstractString)
    q = ["client_id" => client_id, "redirect_uri" => redirect, "response_type" => "code", "scope" => YT_SCOPES,
         "access_type" => "offline", "prompt" => "consent select_account", "code_challenge" => challenge,
         "code_challenge_method" => "S256", "state" => state]
    return GOOGLE_AUTH * "?" * join(("$k=$(HTTP.escapeuri(v))" for (k, v) in q), "&")
end

function free_port()
    s = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(s)[2])
    close(s)
    return port
end

const LOGIN_PAGE = """<!doctype html><meta charset="utf-8"><title>Community</title>
<body style="font-family:system-ui;padding:3em;text-align:center"><h2>%s</h2><p>You can close this tab.</p></body>"""

"""
    start_youtube_login!(app, brand) -> URL

Start logging a YouTube channel in for `brand`: a listener on 127.0.0.1 waits up
to five minutes for Google's redirect; the returned URL is Google's consent
page. Once it comes back, the channel is added as `brand`'s YouTube account.
The browser has to run on this machine (the redirect goes to 127.0.0.1).
"""
function start_youtube_login!(app::CommunityApp, brand::AbstractString)
    b = find_brand(app, brand).name
    "youtube" in find_brand(app, b).platforms || throw(AppError("$b does not post on YouTube"))
    client_id, _ = google_client(app)
    isempty(client_id) && throw(AppError("add the Google OAuth client first"))
    port = free_port()
    redirect = "http://127.0.0.1:$port"
    verifier, state = pkce_verifier(), pkce_verifier()
    answer = Channel{Pair{Symbol,String}}(1)
    server = HTTP.serve!("127.0.0.1", port) do req
        q = HTTP.queryparams(HTTP.URI(req.target))
        get(q, "state", "") == state || return HTTP.Response(400, "unexpected request")
        if haskey(q, "code")
            isready(answer) || put!(answer, :code => q["code"])
            return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"],
                                 replace(LOGIN_PAGE, "%s" => "Connected to YouTube"))
        end
        isready(answer) || put!(answer, :error => get(q, "error", "no code"))
        return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"],
                             replace(LOGIN_PAGE, "%s" => "YouTube login failed: $(get(q, "error", "no code"))"))
    end
    timeout = Timer(_ -> isready(answer) || put!(answer, :error => "no answer within five minutes"), 300)
    errormonitor(Threads.@spawn begin
        kind, value = take!(answer)
        close(timeout)
        close(server)
        r = kind === :code ? attempt(() -> finish_youtube_login!(app, b, value, redirect, verifier), "logging in to YouTube") :
                             "Google said: $value"
        app.notice[] = r isa Account ? "" : "Connecting YouTube failed: $r"
    end)
    return consent_url(client_id, redirect, pkce_challenge(verifier), state)
end

function finish_youtube_login!(app::CommunityApp, brand::AbstractString, code::AbstractString,
                               redirect::AbstractString, verifier::AbstractString)
    id, client_secret = google_client(app)
    t = api("POST", GOOGLE_TOKEN; content_type = "application/x-www-form-urlencoded",
            body = form("code" => code, "client_id" => id, "client_secret" => client_secret, "redirect_uri" => redirect,
                        "grant_type" => "authorization_code", "code_verifier" => verifier))
    haskey(t, "refresh_token") || throw(AppError("Google gave no refresh token; remove the app's access in your Google account and connect again"))
    r = api("GET", "$YT_API/channels"; token = string(t["access_token"]), query = ["part" => "snippet", "mine" => "true"])
    isempty(get(r, "items", [])) && throw(AppError("that Google account has no YouTube channel"))
    ch = r["items"][1]
    handle = lstrip(string(something(get(ch["snippet"], "customUrl", nothing), ch["snippet"]["title"])), '@')
    a = Account("youtube:" * string(ch["id"]), "youtube", brand, handle,
                "https://www.youtube.com/channel/" * string(ch["id"]), "post")
    store_secret!(app, a.id, string(t["refresh_token"]))
    lock(() -> (app.sessions[a.id] = Session(string(t["access_token"]), "", now(UTC))), app.lock)
    update!(s -> with(s; accounts = vcat(filter(x -> x.id != a.id, s.accounts), a)), app)
    return a
end

# ── uploading ───────────────────────────────────────────────────────────────

hashtags(text::AbstractString) = unique!([m.captures[1] for m in eachmatch(r"#([\p{L}\p{N}_]+)", text)])

"""
    upload_resumable(location, file, token; chunk, progress) -> Dict

Send `file` to a resumable upload session in chunks; `progress(sent, total)`
after each. Returns what the server answers to the last chunk.
"""
function upload_resumable(location::AbstractString, file::AbstractString, token::AbstractString;
                          chunk::Int = YT_CHUNK, progress = (sent, total) -> nothing)
    total = filesize(file)
    open(file) do io
        sent = 0
        while sent < total
            n = min(chunk, total - sent)
            bytes = read(io, n)
            r = HTTP.request("PUT", location, ["Authorization" => "Bearer $token", "Content-Length" => string(n),
                                               "Content-Range" => "bytes $sent-$(sent + n - 1)/$total"], bytes;
                             status_exception = false, retry = false, request_timeout = 900)
            sent += n
            r.status in (200, 201) && return JSON.parse(String(r.body))
            r.status == 308 || throw(AppError("the upload failed ($(r.status)): $(api_error_text(r.body))"))
            progress(sent, total)
        end
        throw(AppError("the upload ended without the video"))
    end
end

function publish(::YouTube, app::CommunityApp, a::Account, d::Draft, text::AbstractString)
    isempty(d.media) && throw(AppError("a YouTube draft needs its video file (media)"))
    file = joinpath(project_folder(projects_dir(app), find_project(app, d.project)), d.media[1])
    is_video(file) && isfile(file) || throw(AppError("$(d.media[1]) is not a video in the project folder"))
    token = google_access(app, a)
    meta = Dict("snippet" => Dict("title" => d.title, "description" => text, "tags" => hashtags(text),
                                  "categoryId" => YT_SCIENCE_AND_TECHNOLOGY),
                "status" => Dict("privacyStatus" => app.settings.youtube_privacy, "selfDeclaredMadeForKids" => false))
    r = HTTP.request("POST", "$YT_UPLOAD?uploadType=resumable&part=snippet,status",
                     ["Authorization" => "Bearer $token", "Content-Type" => "application/json; charset=UTF-8",
                      "X-Upload-Content-Length" => string(filesize(file)), "X-Upload-Content-Type" => "video/*"],
                     JSON.json(meta); status_exception = false, retry = false, request_timeout = 60)
    r.status == 200 || throw(AppError("YouTube refused the upload ($(r.status)): $(api_error_text(r.body))"))
    video = upload_resumable(HTTP.header(r, "Location"), file, token;
                             progress = (sent, total) -> set_draft!(app, d.id; note = "Uploading: $(round(Int, 100sent / total)) %"))
    return Post(a.id, "original", string(video["id"]), "", "https://youtu.be/$(video["id"])", now(UTC))
end

# ── comments ────────────────────────────────────────────────────────────────

"The comments of a `commentThreads` answer, top-level ones and their replies. `cid` is the top-level comment an answer attaches to."
function youtube_comments(r, video::AbstractString)
    out = NamedTuple[]
    comment(c, top) = (s = c["snippet"];
        (ref = string(c["id"]), cid = top, author = string(s["authorDisplayName"]),
         author_name = string(s["authorDisplayName"]), text = string(s["textOriginal"]),
         url = "https://www.youtube.com/watch?v=$video&lc=$(c["id"])", created = parse_time(string(s["publishedAt"]))))
    for t in get(r, "items", [])
        top = t["snippet"]["topLevelComment"]
        push!(out, comment(top, string(top["id"])))
        for c in get(get(t, "replies", Dict()), "comments", [])
            push!(out, comment(c, string(top["id"])))
        end
    end
    return out
end

function fetch_stats(::YouTube, app::CommunityApp, a::Account, post::Post)
    r = api("GET", "$YT_API/videos"; token = google_access(app, a), query = ["part" => "statistics", "id" => post.ref])
    isempty(r["items"]) && return Dict{String,Int}()
    st = r["items"][1]["statistics"]
    n(k) = parse(Int, string(get(st, k, "0")))
    return Dict("views" => n("viewCount"), "likes" => n("likeCount"), "replies" => n("commentCount"))
end

function fetch_replies(::YouTube, app::CommunityApp, a::Account, post::Post)
    r = api("GET", "$YT_API/commentThreads"; token = google_access(app, a),
            query = ["part" => "snippet,replies", "videoId" => post.ref, "maxResults" => "100", "order" => "time"])
    return youtube_comments(r, post.ref)
end

function send_answer(::YouTube, app::CommunityApp, a::Account, to::AnswerTo, text::AbstractString)
    api("POST", "$YT_API/comments"; token = google_access(app, a), query = ["part" => "snippet"],
        json = Dict("snippet" => Dict("parentId" => isempty(to.post_cid) ? to.post : to.post_cid, "textOriginal" => text)))
    return nothing
end
