# BonitoCommunity

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

Use **Brands** in the overview to add brands and edit their platforms and
writing instructions. Changes apply immediately and persist in `settings.json`.
Unused brands can be renamed or deleted; names referenced by projects, drafts
or accounts stay fixed to preserve those references.

- Bluesky: handle + app password. Mastodon: handle + access token (read, write).
- YouTube: enable YouTube Data API v3 and create a **Web application** OAuth
  client. Register the callback URL shown in the YouTube card. Save the client
  ID and secret with your PIN, choose a brand and connect its channel. Sign in
  with Google, then return to the dashboard and finish with your PIN. Tokens
  are encrypted; uploads require another explicit PIN-authorised publish action.
- Facebook + Instagram: a long-lived Page access token; it finds the linked Instagram account.

Passwords and tokens are encrypted in `<state_dir>/apps/community/secrets.enc`
(mode 600). The PIN is requested for each credential action and is never saved.
Settings (projects folder, brands and their platforms, watched
forums and repositories, YouTube privacy) are in `settings.json` next to it.

## Running it

    julia --project=devserver devserver/run.jl     # dev server on http://127.0.0.1:8139

## Install as a server plugin

The shared UI requires current BonitoAgents `main` (including merged
[PR #28](https://github.com/SimonDanisch/BonitoAgents.jl/pull/28)). Community
uses its public `AppButton`, `AppCard`, `AppModal` and `AppUIStyles`; all share
the server's BonitoWidgets theme.

Install BonitoCommunity into the same Julia environment from which the normal
BonitoAgents server runs:

    cd /path/to/BonitoAgents.jl
    julia --project=. -e 'using Pkg; Pkg.add("BonitoCommunity")'

Then run `BonitoAgents/assets/install_server.sh` normally. BonitoAgents loads
direct packages that explicitly opt in with `[bonitoagents] plugin = true`; this
package registers the Community app when it loads. No server launcher, systemd
unit or local edit to BonitoAgents is needed.

- Unit tests (network stubbed or faked locally): `julia --project -e 'using Pkg; Pkg.test()'`
- Browser walkthrough with a scripted agent, screenshots in `e2e/shots/`:
  `julia --project=e2e e2e/flow.jl`

## Not verified against the real services

Logging in and posting to Bluesky, Mastodon, YouTube, Facebook and Instagram need
real accounts; the request flows are tested against stubs and local fakes only.
Public reads are checked live: Discourse topics, GitHub releases, Bluesky handles,
YouTube oEmbed.
