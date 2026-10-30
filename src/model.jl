# What the app keeps: the brands it posts for, the accounts it posts with, the
# projects (one folder of material each), the drafts written for them, where
# they were published and the replies they got. Values are immutable; a change
# makes a new one (`change`), so a render keeps the state it was given.

"Who posts: a name and the platforms it has accounts on."
struct Brand
    name::String
    platforms::Vector{String}     # platform ids
    notes::String                 # for the agent: tone, blog, which accounts
end

const DEFAULT_BRANDS = [
    Brand("Makie", ["bluesky", "mastodon", "linkedin", "discourse"],
          "The Makie.jl plotting library. Blog: MakieOrg/Website (src/blogposts), published on makie.org."),
    Brand("Bonito", ["bluesky", "mastodon", "linkedin", "discourse"],
          "Bonito.jl, the web framework behind WGLMakie and BonitoAgents. Blog: Bonito.jl docs/blog."),
    Brand("Makie4Science", ["youtube", "tiktok", "instagram", "facebook", "bluesky", "mastodon", "linkedin"],
          "Videos on how research figures and animations are made with Makie. Its own accounts on the video " *
          "platforms; on Bluesky and Mastodon the Makie and personal accounts repost it. Background posts go on the Makie blog."),
]

"""
An account the app posts or reposts with. `brand` is whose it is ("" for a
personal account); `role` is `post` (publishes the brand's drafts on its
platform) or `amplify` (reposts what the brand's account published). Its
password or token is in `secrets.json`, never here.
"""
struct Account
    id::String                    # "<platform>:<handle>"
    platform::String              # platform id
    brand::String
    handle::String                # makie.org, makie@fosstodon.org
    server::String                # Bluesky PDS / Mastodon instance, https://...
    role::String                  # "post" or "amplify"
end

const ACCOUNT_ROLES = ("post", "amplify")

# A project goes through these in order; `archived` ends it.
const PROJECT_STATES = ("new", "drafting", "review", "publishing", "community", "archived")

JSON.@defaults struct Project
    id::String                    # its folder's name under the projects folder
    title::String
    brands::Vector{String}
    brief::String                 # what it is about and what the posts should say
    state::String                 # one of PROJECT_STATES
    created::DateTime
    chat::String                  # the project chat's id; "" before it is started
    links::Dict{String,String} = Dict{String,String}()   # "youtube" => the video's URL, filled into {youtube_url}
end

"One published copy of a draft: the original, or a repost by an amplifying account."
JSON.@defaults struct Post
    account::String               # Account id
    kind::String                  # "original" or "repost"
    ref::String                   # Bluesky at-uri, Mastodon status id, YouTube video id
    cid::String                   # Bluesky record cid, "" elsewhere
    url::String                   # where people see it
    at::DateTime
    stats::Dict{String,Int} = Dict{String,Int}()   # "views", "likes", "reposts", "replies", as last checked
end

const DRAFT_STATES = ("draft", "approved", "changes", "publishing", "published", "failed")

JSON.@defaults struct Draft
    id::Int
    project::String
    brand::String
    platform::String              # platform id
    kind::String                  # "video", "short", "reel", "post", ...
    title::String
    text::String
    media::Vector{String}         # files, relative to the project folder
    status::String                # one of DRAFT_STATES
    note::String                  # what the user asked to change, or why publishing failed
    posts::Vector{Post} = Post[]  # once published: the original first, then reposts
    reshare_from::Int = 0          # another draft in this project; 0 means publish this as an original
    updated::DateTime = now(UTC)
end

const REPLY_STATES = ("new", "drafted", "answered", "ignored")

"A reply to one of a project's posts, and the answer to it."
struct Reply
    ref::String                   # the reply's own id on its platform
    cid::String                   # Bluesky record cid, "" elsewhere
    project::String
    draft::Int
    platform::String
    account::String               # the account whose post it answers
    author::String                # handle
    author_name::String
    text::String
    url::String
    created::DateTime
    status::String                # one of REPLY_STATES
    answer::String                # the drafted (or sent) answer
end

const INBOX_STATES = ("new", "drafted", "answered", "done", "ignored")

"""
Something for the community manager that no project's post started: a mention
of one of the accounts, or a new topic in a watched forum.
"""
struct InboxItem
    ref::String                   # "<source>:<id>", unique
    source::String                # "bluesky", "mastodon", "discourse"
    kind::String                  # "mention" or "topic"
    account::String               # the account mentioned; "" for a forum topic
    brand::String
    author::String
    author_name::String
    title::String                 # a topic's title; "" for a mention
    text::String
    url::String
    created::DateTime
    status::String                # one of INBOX_STATES
    answer::String
    post::String                  # the mention's own id on its platform (Bluesky: at-uri)
    post_cid::String
    root::String                  # the thread it is in (Bluesky), so an answer threads right; "" for none
    root_cid::String
end

"Something the app watches, for a brand: a Discourse tag or category page (new topics), a GitHub repository (new releases)."
struct Watch
    source::String                # "discourse" or "github"
    brand::String
    url::String                   # https://discourse.julialang.org/tag/makie, https://github.com/MakieOrg/Makie.jl
end

const DEFAULT_WATCHES = [Watch("discourse", "Makie", "https://discourse.julialang.org/tag/makie"),
                         Watch("discourse", "Bonito", "https://discourse.julialang.org/tag/bonito"),
                         Watch("github", "Makie", "https://github.com/MakieOrg/Makie.jl"),
                         Watch("github", "Bonito", "https://github.com/SimonDanisch/Bonito.jl")]

"Where an answer goes: the thread's root, the post it answers, and whom it answers."
struct AnswerTo
    root::String
    root_cid::String
    post::String
    post_cid::String
    author::String
end

change(x::T; kw...) where {T<:Union{Project,Draft,Reply,InboxItem}} = T((get(kw, f, getfield(x, f)) for f in fieldnames(T))...)

# What community.json holds. Draft ids are never reused: a chat told about #5
# must not edit a different #5. Fields added later get their default when an
# older file is read.
JSON.@defaults struct CommunityFile
    next_draft::Int = 1
    accounts::Vector{Account} = Account[]
    projects::Vector{Project} = Project[]
    drafts::Vector{Draft} = Draft[]
    replies::Vector{Reply} = Reply[]
    inbox::Vector{InboxItem} = InboxItem[]
end

# `CommunityFile()` is the empty state: every field's default.

with(s::CommunityFile; kw...) = CommunityFile((get(kw, f, getfield(s, f)) for f in fieldnames(CommunityFile))...)

"`yyyy-mm-<slug>` from a title: the folder name of a new project."
function project_slug(title::AbstractString, date::Date = today())
    slug = replace(lowercase(strip(title)), r"[^a-z0-9]+" => "-")
    slug = strip(slug, '-')
    isempty(slug) && throw(AppError("a project needs a title"))
    return Dates.format(date, "yyyy-mm") * "-" * first(slug, 48)
end

project_folder(projects_dir::AbstractString, p::Project) = joinpath(projects_dir, p.id)

"The files of a project's material, relative to its folder, without hidden ones."
function material(projects_dir::AbstractString, p::Project)
    root = project_folder(projects_dir, p)
    isdir(root) || return String[]
    files = String[]
    for (dir, dirs, names) in walkdir(root; follow_symlinks = true)
        filter!(d -> !startswith(d, "."), dirs)
        for n in names
            startswith(n, ".") || push!(files, relpath(joinpath(dir, n), root))
        end
    end
    return sort!(files)
end

const VIDEO_EXTS = (".mp4", ".webm", ".mov", ".m4v")
const IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")
const POST_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp")
is_video(file::AbstractString) = lowercase(splitext(file)[2]) in VIDEO_EXTS
is_image(file::AbstractString) = lowercase(splitext(file)[2]) in IMAGE_EXTS
is_post_image(file::AbstractString) = lowercase(splitext(file)[2]) in POST_IMAGE_EXTS

"The image formats the Bluesky and Mastodon upload APIs accept from Community."
function image_content_type(file::AbstractString)
    ext = lowercase(splitext(file)[2])
    ext == ".png" && return "image/png"
    ext in (".jpg", ".jpeg") && return "image/jpeg"
    ext == ".gif" && return "image/gif"
    ext == ".webp" && return "image/webp"
    throw(AppError("$file is not a supported post image (use PNG, JPEG, GIF or WebP)"))
end

"The persistent server paths of a draft's native images."
function draft_images(app, d::Draft)
    p = find_project(app, d.project)
    files = [joinpath(project_folder(projects_dir(app), p), media) for media in d.media]
    for file in files
        isfile(file) || throw(AppError("$(basename(file)) is no longer in the project folder"))
        image_content_type(file)
    end
    return files
end
