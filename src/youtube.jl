# YouTube (Data API v3): a Google login per channel (web OAuth with PKCE
# and a callback on the home server), resumable uploads, and the
# comments under a video as the project's replies.
#
# The OAuth client is a "Web application" client of the user's Google Cloud project
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

function set_google_client_with_pin!(app::CommunityApp, id::AbstractString, secret_::AbstractString, pin::AbstractString)
    vault_exists(app) || throw(AppError("set a Community PIN before adding the Google client"))
    return with_vault!(app, pin) do
        set_google_client!(app, id, secret_)
    end
end

form(pairs...) = Vector{UInt8}(HTTP.escapeuri(Dict(pairs)))

"A fresh access token for `a`'s channel, from its refresh token; kept for 50 minutes (they live an hour)."
function google_access(app::CommunityApp, a::Account)
    vault_active(app) || throw(AppError("enter the Community PIN before accessing YouTube"))
    s = lock(() -> get(app.sessions, a.id, nothing), app.lock)
    s === nothing || now(UTC) - s.at > Minute(50) || return s.access
    id, client_secret = google_client(app)
    r = api("POST", GOOGLE_TOKEN; content_type = "application/x-www-form-urlencoded",
            body = form("client_id" => id, "client_secret" => client_secret, "refresh_token" => secret(app, a),
                        "grant_type" => "refresh_token"))
    lock(() -> (app.sessions[a.id] = Session(r["access_token"], "", now(UTC))), app.lock)
    return string(r["access_token"])
end

const YOUTUBE_CALLBACK = "/community-youtube-callback"

function begin_youtube_login!(app::CommunityApp, brand::AbstractString, redirect::AbstractString, pin::AbstractString)
    b = find_brand(app, brand)
    "youtube" in b.platforms || throw(AppError("$(b.name) does not post on YouTube"))
    uri = HTTP.URI(redirect)
    uri.path == YOUTUBE_CALLBACK && isempty(uri.query) && isempty(uri.fragment) &&
        (uri.scheme == "https" || (uri.scheme == "http" && uri.host in ("127.0.0.1", "localhost"))) ||
        throw(AppError("use the server's HTTPS callback URL (HTTP is allowed on localhost)"))
    id = with_vault!(app, pin) do
        first(google_client(app))
    end
    isempty(id) && throw(AppError("save the Google OAuth client first"))
    state, verifier = pkce_verifier(), pkce_verifier()
    lock(app.lock) do
        filter!(p -> now(UTC) - p.second.created < Minute(10), app.youtube_logins)
        app.youtube_logins[state] = (brand=b.name, redirect=String(redirect), verifier, created=now(UTC), code="", error="")
    end
    srv = app.ctx.server.srv
    srv === nothing || Bonito.route!(srv, YOUTUBE_CALLBACK => context -> youtube_callback!(app, context.request))
    return state, consent_url(id, redirect, pkce_challenge(verifier), state)
end

function youtube_callback!(app::CommunityApp, req)
    q = HTTP.queryparams(HTTP.URI(req.target))
    status = lock(app.lock) do
        state = get(q, "state", "")
        pending = get(app.youtube_logins, state, nothing)
        pending === nothing && return 400
        now(UTC) - pending.created < Minute(10) || return 400
        isempty(pending.code) && isempty(pending.error) || return 400
        code, error = get(q, "code", ""), get(q, "error", "")
        isempty(code) && isempty(error) && return 400
        app.youtube_logins[state] = merge(pending, (; code, error))
        return 200
    end
    notify(app.state)
    message = status == 200 ? "Return to Community and enter your PIN to finish connecting YouTube." : "This login has expired or is invalid. Start again in Community."
    return HTTP.Response(status, ["Content-Type"=>"text/html; charset=utf-8", "Cache-Control"=>"no-store", "Referrer-Policy"=>"no-referrer"], replace(LOGIN_PAGE, "%s"=>message))
end

function complete_youtube_login!(app::CommunityApp, state::AbstractString, pin::AbstractString; token_url=GOOGLE_TOKEN, channels_url="$YT_API/channels")
    return with_vault!(app, pin) do
        pending = get(app.youtube_logins, state, nothing)
        pending === nothing && throw(AppError("start connecting YouTube again"))
        now(UTC) - pending.created < Minute(10) || throw(AppError("YouTube login expired; start again"))
        isempty(pending.error) || throw(AppError("Google declined the login; start again"))
        isempty(pending.code) && throw(AppError("finish signing in with Google first"))
        # Consume once: an OAuth code cannot be exchanged twice.
        delete!(app.youtube_logins, state)
        finish_youtube_login!(app, pending.brand, pending.code, pending.redirect, pending.verifier; token_url, channels_url)
    end
end

# ── logging in ──────────────────────────────────────────────────────────────

const URLSAFE = ['A':'Z'; 'a':'z'; '0':'9'; '-'; '.'; '_'; '~']
pkce_verifier() = replace(base64encode(sodium_random(48)), '+' => '-', '/' => '_')
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

function finish_youtube_login!(app::CommunityApp, brand::AbstractString, code::AbstractString,
                               redirect::AbstractString, verifier::AbstractString; token_url=GOOGLE_TOKEN, channels_url="$YT_API/channels")
    id, client_secret = google_client(app)
    t = api("POST", token_url; content_type = "application/x-www-form-urlencoded",
            body = form("code" => code, "client_id" => id, "client_secret" => client_secret, "redirect_uri" => redirect,
                        "grant_type" => "authorization_code", "code_verifier" => verifier))
    haskey(t, "refresh_token") || throw(AppError("Google gave no refresh token; remove the app's access in your Google account and connect again"))
    r = api("GET", channels_url; token = string(t["access_token"]), query = ["part" => "snippet", "mine" => "true"])
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
