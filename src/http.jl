# One way to talk to the platforms' APIs: JSON in, JSON out, a failed request is
# an AppError that says which call failed and what the platform answered.

function api(method::AbstractString, url::AbstractString; token::AbstractString = "", json = nothing,
             body::Union{Vector{UInt8},Nothing} = nothing, content_type::AbstractString = "",
             query = nothing, headers::Vector{Pair{String,String}} = Pair{String,String}[])
    hs = copy(headers)
    isempty(token) || push!(hs, "Authorization" => "Bearer $token")
    payload = UInt8[]
    if json !== nothing
        push!(hs, "Content-Type" => "application/json")
        payload = Vector{UInt8}(JSON.json(json))
    elseif body !== nothing
        isempty(content_type) || push!(hs, "Content-Type" => content_type)
        payload = body
    end
    r = HTTP.request(method, url, hs, payload; query, status_exception = false, retry = false,
                     connect_timeout = 15, request_timeout = 60)
    if r.status >= 300
        path = first(split(url, '?'))
        throw(AppError("$method $path failed ($(r.status)): $(api_error_text(r.body))"))
    end
    return isempty(r.body) ? nothing : JSON.parse(String(r.body))
end

# What a platform says went wrong: its JSON `message`/`error`, else the start of the body.
function api_error_text(body::Vector{UInt8})
    s = String(copy(body))
    startswith(lstrip(s), "{") || return first(strip(s), 200)
    d = JSON.parse(s)
    return string(get(d, "message", get(d, "error_description", get(d, "error", first(s, 200)))))
end

"Bytes of a file on the web (a thumbnail), and its content type."
function fetch_bytes(url::AbstractString)
    r = HTTP.request("GET", url; status_exception = false, retry = false, connect_timeout = 15, request_timeout = 60)
    r.status == 200 || throw(AppError("GET $url failed ($(r.status))"))
    return r.body, HTTP.header(r, "Content-Type", "application/octet-stream")
end

iso(t::DateTime) = Dates.format(t, dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
# Platforms send ISO 8601 with `Z` or an offset, with or without fractions.
function parse_time(s::AbstractString)
    m = match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?", s)
    m === nothing && return now(UTC)
    return DateTime(m.captures[1])
end

"Plain text from a platform's HTML (Mastodon statuses): line breaks kept, tags dropped."
function html_text(html::AbstractString)
    s = replace(html, r"<br\s*/?>"i => "\n", r"</p>\s*<p>"i => "\n\n")
    s = replace(s, r"<[^>]+>" => "")
    for (e, c) in ("&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'", "&apos;" => "'", "&nbsp;" => " ")
        s = replace(s, e => c)
    end
    return strip(replace(s, "&amp;" => "&"))
end
