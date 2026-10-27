# The Community app on a local BonitoAgents dev server, next to the built-in apps.
#
#     julia --project=devserver devserver/run.jl
#
# Its state (chats, the app's community.json and settings.json) stays in
# .devserver/ between runs.
using BonitoAgents, CommunityManager

h = BonitoAgents.dev_server(; port = 8139, dir = joinpath(dirname(@__DIR__), ".devserver"),
                            apps = (BonitoAgents.BUILTIN_APPS..., CommunityApp))
BonitoAgents.wait!(h)
