# The platforms a project's material goes to. Each is a type, so what differs
# between them (limits, how the material is used, how to publish) is a method,
# not a branch. Bluesky and Mastodon are published by the app (bluesky.jl,
# mastodon.jl); the others are posted by hand and their link pasted back.

abstract type Platform end
struct YouTube <: Platform end
struct TikTok <: Platform end
struct Instagram <: Platform end
struct Facebook <: Platform end
struct Bluesky <: Platform end
struct Mastodon <: Platform end
struct LinkedIn <: Platform end
struct Discourse <: Platform end

const PLATFORMS = (YouTube(), TikTok(), Instagram(), Facebook(), Bluesky(), Mastodon(), LinkedIn(), Discourse())

platform_id(p::Platform) = lowercase(platform_name(p))
platform_name(p::Platform) = string(nameof(typeof(p)))

function find_platform(id::AbstractString)
    i = findfirst(p -> platform_id(p) == lowercase(strip(id)), PLATFORMS)
    i === nothing && throw(AppError("unknown platform '$id' (known: $(join(platform_id.(PLATFORMS), ", ")))"))
    return PLATFORMS[i]
end

# Post text, in characters. Mastodon's is the default; a server may allow more.
max_text(::YouTube) = 5000        # the description
max_text(::TikTok) = 2200
max_text(::Instagram) = 2200
max_text(::Facebook) = 63206
max_text(::Bluesky) = 300
max_text(::Mastodon) = 500
max_text(::LinkedIn) = 3000
max_text(::Discourse) = 32000

# Only YouTube has a separate title.
max_title(::Platform) = 0
max_title(::YouTube) = 100
max_title(::Discourse) = 120

"Whether the app publishes there itself; elsewhere the user posts by hand and pastes the link."
publishes(::Platform) = false
publishes(::Bluesky) = true
publishes(::Mastodon) = true
publishes(::YouTube) = true

"Whether the other accounts repost what was published there."
reposts(::Platform) = true
reposts(::YouTube) = false

"Whether a draft there carries media files."
carries_media(::Platform) = true

"The native-image platforms have deliberately small, predictable limits."
max_images(::Platform) = typemax(Int)
max_images(::Bluesky) = 4
max_images(::Mastodon) = 4

# Drafts link to the project's video and blog post with these placeholders; they
# are filled in from the project's links when it is published, and counted as a
# link of that kind.
const YOUTUBE_LINK = "{youtube_url}"
const BLOG_LINK = "{blog_url}"
const LINK_PLACEHOLDERS = ("youtube" => YOUTUBE_LINK, "blog" => BLOG_LINK)
const LINK_EXAMPLES = (YOUTUBE_LINK => "https://youtu.be/xxxxxxxxxxx", BLOG_LINK => "https://makie.org/website/blogposts/xxxxxxxxxxxx/")

text_length(p::Platform, text::AbstractString) = count_chars(p, replace(text, LINK_EXAMPLES...))
count_chars(::Platform, s::AbstractString) = length(s)
count_chars(::Bluesky, s::AbstractString) = length(Base.Unicode.graphemes(s))

# What a project's material becomes there: the plan the drafting agent follows.
role(::YouTube) = "the full video (16:9) as the main upload, plus up to 3 vertical Shorts (≤ 3 min) cut from it. " *
                  "Title ≤ 100 chars; description with chapters (start at 0:00, at least 3, each ≥ 10 s) and links."
role(::TikTok) = "the video natively, vertical if possible; over 1 min so it counts for Creator Rewards. " *
                 "It arrives as a draft in the TikTok app."
role(::Instagram) = "a vertical Reel of at most 3 min, as a collab post with the Makie account."
role(::Facebook) = "the full video as a Page video post."
role(::Bluesky) = "a short hook, up to four native images and (when useful) a link to the YouTube video ($YOUTUBE_LINK). " *
                  "Hashtags and @handles work. A second brand can explicitly reshare the original."
role(::Mastodon) = "a short hook, up to four native images and (when useful) a link to the YouTube video ($YOUTUBE_LINK). " *
                   "Hashtags help discovery there. A second brand can explicitly boost the original."
role(::LinkedIn) = "posted by hand: a native clip, with the YouTube link ($YOUTUBE_LINK) in the first comment. " *
                   "The draft is the post text; put the comment after a line `---`."
role(::Discourse) = "posted by hand as a new forum topic. Give it a concise title and a Markdown announcement; " *
                    "include the relevant release or documentation link."

function check_draft_text(p::Platform, title::AbstractString, text::AbstractString)
    n = text_length(p, text)
    n > max_text(p) && throw(AppError("$(platform_name(p)) allows $(max_text(p)) characters, the text has $n"))
    if max_title(p) == 0
        isempty(strip(title)) || throw(AppError("$(platform_name(p)) posts have no title; put everything in `text`"))
    else
        t = length(title)
        t > max_title(p) && throw(AppError("$(platform_name(p)) allows a $(max_title(p))-character title, this one has $t"))
    end
    return nothing
end

function check_draft_media(p::Platform, media::Vector{String})
    carries_media(p) || isempty(media) || throw(AppError("$(platform_name(p)) drafts carry no media"))
    length(media) <= max_images(p) || throw(AppError("$(platform_name(p)) allows at most $(max_images(p)) images"))
    if p isa Union{Bluesky,Mastodon}
        all(is_post_image, media) || throw(AppError("$(platform_name(p)) posts can only attach images (PNG, JPEG, GIF or WebP)"))
    end
    return nothing
end

"The links a draft's text needs that the project doesn't have yet."
missing_links(text::AbstractString, p::Project) =
    [key for (key, placeholder) in LINK_PLACEHOLDERS if occursin(placeholder, text) && isempty(get(p.links, key, ""))]

"`text` with the links the project has filled in; placeholders it has no link for stay."
function fill_known_links(text::AbstractString, p::Project)
    known = [placeholder => p.links[key] for (key, placeholder) in LINK_PLACEHOLDERS if haskey(p.links, key)]
    return isempty(known) ? String(text) : replace(text, known...)
end

"The draft's text as it is published: the project's links filled in."
function fill_links(text::AbstractString, p::Project)
    missing_ = missing_links(text, p)
    isempty(missing_) || throw(AppError("the draft links to the project's $(join(missing_, " and ")): set that link first"))
    return fill_known_links(text, p)
end

# ── what a platform the app publishes to implements ─────────────────────────
#
#   account_server(platform, handle, server) -> the API's base URL
#   verify_account(platform, account, secret)   (throws if the credentials don't work)
#   publish(platform, app, account, draft, text) -> Post
#   repost(platform, app, account, original::Post) -> Post
#   fetch_replies(platform, app, account, post::Post) -> Vector of reply NamedTuples
#   fetch_mentions(platform, app, account) -> Vector of mention NamedTuples
#   send_answer(platform, app, account, to::AnswerTo, text) -> nothing

account_server(::Platform, handle::AbstractString, server::AbstractString) = server
fetch_mentions(::Platform, ::Any, ::Account) = NamedTuple[]     # none to check (YouTube's come as comments)
#   fetch_stats(platform, app, account, post::Post) -> Dict("views", "likes", "reposts", "replies" => count)
verify_account(p::Platform, ::Account, ::AbstractString) =
    throw(AppError("the app does not publish to $(platform_name(p)) yet: post there by hand and paste the link"))

"A login kept for a while: a Bluesky session (with the account's DID), a Google access token (`did` empty)."
struct Session
    access::String
    did::String
    at::DateTime
end
