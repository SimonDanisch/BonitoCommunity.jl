"""
    CommunityManager

A BonitoAgents app for the community work around Makie, Bonito and
Makie4Science. One project per video or other material (a folder under
`projects/`), each with a chat of its own: its agent drafts the posts for every
platform, the user approves them in the project's pane, the app publishes them
(Bluesky, Mastodon; the rest by hand) and has the other accounts repost them,
then collects the replies and their answers.

Run it next to the built-in apps:

    BonitoAgents.serve(; apps = (BonitoAgents.BUILTIN_APPS..., CommunityApp))
"""
module CommunityManager

import BonitoAgents
using BonitoAgents: AgentApp, AppContext, AppTool, Param, ToolScope, AppChat, AppKeyedChats, AppCall, AppError,
    ProjectInfo, ChatHeader, ChatNotice, ChatTranscript, ChatComposer, ChatToolbar,
    caller_user, app_chat, chat_title, chat_key, chat_file_url, find_worker, start_chat!, show_chat!,
    send_message!, atomic_write_json, load_json_tolerant, relative_time_label
using Bonito
using Dates
using Base64: base64encode
import HTTP, JSON, SHA, Sockets

export CommunityApp

include("model.jl")
include("platforms.jl")
include("http.jl")
include("app.jl")
include("bluesky.jl")
include("mastodon.jl")
include("youtube.jl")
include("meta.jl")
include("publish.jl")
include("replies.jl")
include("inbox.jl")
include("tools.jl")
include("pane.jl")

end # module CommunityManager
