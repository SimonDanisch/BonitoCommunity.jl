"""
    BonitoCommunity

A BonitoAgents app for the community work around Makie, Bonito and
Makie4Science. One project per video or other material (a folder under
`projects/`), each with a chat of its own: its agent drafts the posts for every
platform, the user approves them in the project's pane, the app publishes them
(Bluesky, Mastodon; the rest by hand) and has the other accounts repost them,
then collects the replies and their answers.

Run it next to the built-in apps:

    Pkg.add("BonitoCommunity")

The ordinary BonitoAgents server discovers this package when it is installed as
a direct dependency and its Project.toml has `[bonitoagents] plugin = true`.
"""
module BonitoCommunity

import BonitoAgents
using BonitoAgents: AgentApp, AppContext, AppTool, Param, ToolScope, AppChat, AppKeyedChats, AppCall, AppError,
    AppButton, AppCard, AppModal, AppUIStyles,
    ProjectInfo, ChatHeader, ChatNotice, ChatTranscript, ChatComposer, ChatToolbar,
    caller_user, app_chat, chat_title, chat_key, chat_file_url, find_worker, start_chat!, show_chat!,
    send_message!, atomic_write_json, load_json_tolerant, relative_time_label
using Bonito
import BonitoWidgets
using Dates
using Base64: base64encode, base64decode
import HTTP, JSON, SHA, Sockets, libsodium_jll

export CommunityApp

function __init__()
    sodium_init!()
    BonitoAgents.register_app!(CommunityApp)
end

include("model.jl")
include("platforms.jl")
include("http.jl")
include("vault.jl")
include("app.jl")
include("bluesky.jl")
include("mastodon.jl")
include("youtube.jl")
include("meta.jl")
include("publish.jl")
include("replies.jl")
include("inbox.jl")
include("project_files.jl")
include("tools.jl")
include("pane.jl")

end # module BonitoCommunity
