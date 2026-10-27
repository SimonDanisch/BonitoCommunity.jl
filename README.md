# CommunityManager

A BonitoAgents app for the community work around Makie, Bonito and Makie4Science.

## How it works

- **Projects.** One folder per video or piece of material in `projects/` (not in git).
  Create one in the overview or drop a folder in; a new GitHub release of Makie or
  Bonito can start one too (its blog post and the announcements).
- **Drafting.** "Start drafting" asks the overview's agent to start the project's own
  chat, in its folder. That agent writes one draft per brand and platform with its
  `project_*` tools (and may cut Shorts, thumbnails, transcripts into the folder).
- **Review.** The project's chat shows the project beside the conversation: material,
  brief, links, draft cards per platform. Approve, edit (double-click), or send back
  with a note, which goes to the project's agent.
- **Publishing**, with a click, never by an agent:
  - YouTube: resumable upload of the video or Short; its link fills `{youtube_url}`.
  - Bluesky, Mastodon: link posts with link cards; the other accounts repost.
  - Facebook Page (chunked video upload), Instagram (Reel).
  - TikTok, LinkedIn: "Copy text", post by hand, "Mark published".
- **Community.** Replies and comments to the published posts come into the project
  (checked every 5 min on day 1, hourly in week 1, daily until day 30); the agent
  drafts answers, a click sends them. Likes, reposts, views are counted on the cards.
- **Inbox** (overview): mentions of the accounts that belong to no project, new topics
  on the watched Discourse tags, new GitHub releases.

## Accounts (overview → Accounts)

- Bluesky: handle + app password. Mastodon: handle + access token (read, write).
- YouTube: a Google Cloud OAuth client ("Desktop app", YouTube Data API v3), then
  "Connect channel", which logs in through Google in a new tab (loopback to
  127.0.0.1, so the browser must run on the server's machine). Until Google audits
  the API project, uploads are private (`youtube_privacy` in settings).
- Facebook + Instagram: a long-lived Page access token; it finds the linked Instagram account.

Passwords and tokens are in `<state_dir>/apps/community/secrets.json` (mode 600),
nothing else. Settings (projects folder, brands and their platforms, watched
forums and repositories, YouTube privacy) are in `settings.json` next to it.

## Running it

    julia --project=devserver devserver/run.jl     # dev server on http://127.0.0.1:8139

BonitoAgents comes from `../AgentsDev/dev/BonitoAgents` (branch `sd/community-app`,
which adds keyed app chats, `AppKeyedChats`, `chat_key` and `chat_file_url`).

- Unit tests (network stubbed or faked locally): `julia --project -e 'using Pkg; Pkg.test()'`
- Browser walkthrough with a scripted agent, screenshots in `e2e/shots/`:
  `julia --project=e2e e2e/flow.jl`

## Not verified against the real services

Logging in and posting to Bluesky, Mastodon, YouTube, Facebook and Instagram need
real accounts; the request flows are tested against stubs and local fakes only.
Public reads are checked live: Discourse topics, GitHub releases, Bluesky handles,
YouTube oEmbed.
