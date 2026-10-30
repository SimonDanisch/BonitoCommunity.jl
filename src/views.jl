# Julia owns the structure. Each bounded region / keyed item updates only when
# its own inputs change, so unrelated updates preserve form and media nodes.
mutable struct CommunityRegion
    key::String
    signature::String
    content::Observable{Any}
end
Bonito.jsrender(s::Bonito.Session, r::CommunityRegion) = Bonito.jsrender(s, DOM.div(r.content; class = "cm-region"))
Base.close(r::CommunityRegion) = Bonito.Observables.clear(r.content)

function region!(cache, key, payload, build)
    r = get!(cache, key) do
        CommunityRegion(key, "", Observable{Any}(DOM.div(; hidden = true)))
    end
    signature = JSON.json(payload)
    if r.signature != signature
        r.signature = signature
        r.content[] = build()
    end
    return r
end

# Small helpers keep attributes declarative, including data attributes consumed
# by the browser controller. Dynamic colours use Styles, never CSS strings.
function node(tag, cls, children...; kw...)
    content = filter(!isnothing, collect(children))
    if "cm-card" in split(cls)
        return AppCard(content...; tag = Symbol(tag), class = cls, kw...)
    end
    return getproperty(DOM, Symbol(tag))(content...; class = cls, kw...)
end
box(cls, children...; kw...) = node("div", cls, children...; kw...)
label(text) = box("cm-h2", text)
hint(text) = box("cm-hint", text)
spacer() = node("span", "cm-spacer")
function button(text, action; kind = "secondary", id = nothing, value = nothing, num = nothing, kw...)
    attrs = Dict{Symbol,Any}(Symbol("data-act") => action)
    isnothing(id) || (attrs[Symbol("data-id")] = id)
    isnothing(value) || (attrs[Symbol("data-value")] = value)
    isnothing(num) || (attrs[Symbol("data-num")] = num)
    AppButton(text; variant = Symbol(kind), size = :small, attrs..., kw...)
end
link(text, url; cls = "cm-sub") = node("a", cls, text; href = url, target = "_blank", rel = "noopener")
status(text) = node("span", "cm-status cm-status-$text", text)
field(text, input) = node("label", "cm-field", text, input)
input(name, placeholder; type = "text", kw...) = node("input", "cm-input"; name, placeholder, type, autocomplete = type == "password" ? "new-password" : "off", kw...)
function dropdown(name, options; selected = "", kw...)
    node("select", "cm-select", [node("option", "", x; value = x, selected = x == selected) for x in options]...; name, kw...)
end
const BRAND_COLORS = Dict("Makie" => "#e05a7a", "Bonito" => "#2f9e8f", "Makie4Science" => "#3a7fc4")
brand_style(name) = Styles("--dot" => get(BRAND_COLORS, name, "var(--bw-accent)"))
brand_pill(name) = node("span", "cm-pill cm-pill-dot", name; style = brand_style(name))
function brands_toggle(brands, selected; project = "")
    box("cm-row", [node("button", "cm-pill cm-pill-dot cm-brand-toggle" * (b in selected ? " cm-on" : ""), b;
        type = "button", style = brand_style(b), dataAct = "brand", dataValue = b) for b in brands]...; dataBrands = project)
end
const PLATFORM_GLYPHS = Dict("youtube" => "▶", "bluesky" => "🦋", "mastodon" => "m", "facebook" => "f",
    "instagram" => "◎", "tiktok" => "♪", "linkedin" => "in", "discourse" => "D", "github" => "GH")
function badge(id; small = false)
    node("span", "cm-plat" * (small ? " cm-plat-sm" : ""), get(PLATFORM_GLYPHS, id, uppercase(first(id, 1)));
         title = id, style = Styles("--plat" => get(PLATFORM_COLORS, id, "#888")))
end
stats(s) = box("cm-stats", join(["$(s[k]) $k" for k in ("views", "likes", "reposts", "replies") if get(s, k, 0) > 0], " · "))
function stepper(states, state)
    index = findfirst(==(state), states)
    box("cm-steps", [box("cm-step" * (i < index ? " cm-step-done" : i == index ? " cm-step-now" : "")) for i in eachindex(states)]...)
end

function pin_dialog(open)
    modal = AppModal(open; title = "Community credentials") do
        node("form", "cm-pin-form", box("cm-h2", ""; dataPin = "title"), hint("Credentials are unlocked only for this action."),
             input("pin", "Community PIN"; type = "password"), input("pin_confirmation", "Repeat PIN"; type = "password"),
             box("cm-hint", ""; dataPin = "error"),
             box("cm-row", button("Continue", "pin-submit"; kind = "primary"), button("Cancel", "pin-cancel"; kind = "ghost"));
             autocomplete = "off")
    end
    return box("cm-pin-dialog", modal)
end

function network_card(d, platform, title, instructions, handle_label, placeholder, secret_label)
    brand_names = [b for b in d["brands"] if platform in d["brand_platforms"][b]]
    credential_form(role) = box("cm-form-grid",
        role == "post" ? field("Post as", dropdown("brand", brand_names)) : nothing,
        field(handle_label, input("handle", placeholder)), field(secret_label, input("secret", ""; type = "password")); dataAccountForm = role)
    configured = [box("cm-account", node("span", "cm-account-handle", "@" * a["handle"]),
                      isempty(a["brand"]) ? hint("personal reposts") : brand_pill(a["brand"]),
                      button("Remove", "remove-account"; id = a["id"], kind = "ghost")) for a in d["accounts"] if a["platform"] == platform]
    connect(text, role) = button(text, "add-account"; kind = "primary", dataPlatform = platform, dataRole = role)
    node("section", "cm-card cm-platform-card",
        box("cm-platform-head", badge(platform), box("", label(title), hint("Automatic publishing"))),
        isempty(configured) ? hint("Not connected yet.") : box("cm-configured", configured...),
        node("ol", "cm-credential-steps", [node("li", "", x) for x in instructions]...),
        credential_form("post"), box("cm-row", connect("Check and connect $title", "post")),
        node("details", "cm-amplify", node("summary", "", "Optional: add a personal account that reposts releases"),
             credential_form("amplify"), box("cm-row", connect("Check and add repost account", "amplify")));
        dataBox = "account-$platform")
end
function manual_card(id, title, text)
    node("section", "cm-card cm-platform-card", box("cm-platform-head", badge(id), box("", label(title), hint("Manual posting — no credentials stored"))), box("cm-manual-copy", text))
end
function youtube_card(d)
    configured = [box("cm-account", node("span", "cm-account-handle", a["handle"]), brand_pill(a["brand"]),
        button("Remove", "remove-account"; id=a["id"], kind="ghost")) for a in d["accounts"] if a["platform"] == "youtube"]
    node("section", "cm-card cm-platform-card",
        box("cm-platform-head", badge("youtube"), box("", label("YouTube"), hint("Automatic video and Shorts uploads"))),
        configured,
        node("ol", "cm-credential-steps",
            node("li", "", "In Google Cloud, enable YouTube Data API v3."),
            node("li", "", "Configure Google Auth Platform → Branding and Audience. While in testing, add your Google account as a test user."),
            node("li", "", "Create an OAuth client of type Web application. Add the callback URL shown below as an authorised redirect URI, then copy its client ID and secret.")),
        field("Authorised redirect URI", input("youtube_redirect", ""; readonly=true, dataYoutubeRedirect="true")),
        field("Client ID", input("google_id", "…apps.googleusercontent.com")),
        field("Client secret", input("google_secret", ""; type="password")),
        button("Save Google client", "google-client"; kind="primary"),
        field("Post as", dropdown("youtube_brand", d["youtube_brands"])),
        button("Connect channel", "connect-youtube"; kind="primary"),
        isempty(d["youtube_url"]) ? nothing : box("cm-stack",
            node("a", "", "Sign in with Google"; href=d["youtube_url"], target="_blank", rel="noopener noreferrer"),
            hint("After Google returns you here, click Finish connection. Your PIN is required to encrypt the channel credentials."),
            button("Finish connection", "finish-youtube"; kind="primary")),
        hint("Uploads start as $(d["youtube_privacy"]). Google may restrict unaudited API projects to private uploads."); dataBox="youtube")
end
function accounts_view(d)
    header = [label("Publishing accounts"), hint("Connect the platforms you want to publish to. Credentials are encrypted with your Community PIN.")]
    if !d["vault_set"]
        return box("cm-card cm-panel", header..., hint("First set a Community PIN. It encrypts credentials but is never stored."), button("Set Community PIN", "set-pin"; kind = "primary"); dataBox = "accounts")
    end
    grid = box("cm-platform-grid",
        network_card(d, "bluesky", "Bluesky", ["Open Settings → Privacy and security → App passwords.", "Create an app password named Community; never use your normal password.", "Enter your handle and app password below."], "Bluesky handle", "makie.org", "App password"),
        network_card(d, "mastodon", "Mastodon", ["Open your instance → Preferences → Development → New application.", "Grant read and write scopes, then copy its access token.", "Enter your full handle including the instance."], "Full Mastodon handle", "makie@fosstodon.org", "Access token"),
        manual_card("linkedin", "LinkedIn", "Approve the draft, copy the text, publish it on LinkedIn, then paste the resulting URL back here."),
        manual_card("discourse", "Discourse", "Approve the forum-topic draft, copy it to Discourse, publish it, then paste the topic URL back here."),
        youtube_card(d),
        node("section", "cm-card cm-platform-card", box("cm-platform-head", badge("facebook"), badge("instagram"), label("Facebook Page + Instagram")),
             hint("Create a Meta Business app and Page token with pages_manage_posts, pages_read_engagement, instagram_basic and instagram_content_publish permissions. Link a Professional Instagram account to the Page."),
             field("Post as", dropdown("meta_brand", d["meta_brands"])), field("Page access token", input("page_token", ""; type = "password")),
             button("Check and connect Page", "add-meta"; kind = "primary"); dataBox = "meta"))
    box("cm-card cm-panel", header..., grid, button("Close", "toggle-accounts"; kind = "ghost"); dataBox = "accounts")
end

function brands_view(data)
    function editor(b)
        name = b["name"]
        box("cm-card cm-panel",
            field("Brand name", input("brand_name", "e.g. My project"; value=name, readonly=b["in_use"])),
            b["in_use"] ? hint("This name is used by projects or accounts. Platforms and instructions can be edited here.") : nothing,
            label("Platforms"),
            box("cm-row", [node("label", "cm-field", node("input", ""; type="checkbox", name="brand_platform", value=p["id"], checked=p["id"] in b["platforms"]), p["name"]) for p in data["platforms"]]),
            field("Writing instructions", node("textarea", "cm-input", b["notes"]; name="brand_notes", rows=4, placeholder="Topics, tone, audience and links for the agent")),
            box("cm-row", button(isempty(name) ? "Create brand" : "Save brand", "save-brand"; id=name, kind="primary"),
                isempty(name) || b["in_use"] ? nothing : button("Delete brand", "delete-brand"; id=name, kind="danger")); dataBox="brand-editor")
    end
    box("cm-panel", label("Brands"), hint("Changes are saved on the server and survive redeployments."),
        [editor(b) for b in data["brand_details"]],
        label("Add a brand"), editor(Dict("name"=>"", "platforms"=>String[], "notes"=>"", "in_use"=>false)),
        button("Close", "toggle-brands"; kind="ghost"))
end

function new_project_view(d)
    box("cm-card cm-panel", label("New project"), input("title", "Title, e.g. BonitoAgents release"), brands_toggle(d["brands"], String[]),
        node("textarea", "cm-textarea"; name = "brief", placeholder = "What it is about, what the posts should say"),
        hint("Creates a folder in $(d["folder"])."), box("cm-row", button("Create project", "create"; kind = "primary"), button("Cancel", "toggle-new"; kind = "ghost")); dataBox = "new")
end
function cover_view(p)
    c = p["cover"]
    content = isnothing(c) ? node("span", "cm-cover-letter", uppercase(first(p["title"], 1))) :
        c["video"] ? node("video", ""; src = c["url"] * "#t=2", preload = "metadata", muted = true, playsinline = true) :
        node("img", ""; src = c["url"], alt = "", loading = "lazy")
    box("cm-cover", content)
end
function project_card_view(d, p)
    started = !isnothing(p["chat"])
    body = box("cm-project-body", box("cm-row", box("cm-project-title", p["title"]; dataEditTitle = p["id"]), spacer(), status(p["state"])), stepper(d["states"], p["state"]),
        started ? box("cm-row", brand_pill.(p["brands"])...) : brands_toggle(d["brands"], p["brands"]; project = p["id"]),
        hint("$(p["counts"]["review"]) to review · $(p["counts"]["published"]) published"), stats(p["stats"]),
        started ? nothing : box("cm-row", hint(p["brief"]), spacer(), button("Start drafting", "start"; id = p["id"], kind = "primary", disabled = isempty(p["brands"]))))
    box("cm-card cm-project", cover_view(p), body; dataAct = "open-card", dataChat = started ? p["chat"] : "")
end

function message_card(x; inbox = false)
    ref = x["ref"]
    state = x["status"]
    source = inbox ? x["source"] : x["platform"]
    done = !(state in ("new", "drafted"))
    text = box("cm-section", box("cm-row", node("strong", "", x["author_name"]), node("span", "cm-sub", "@$(x["author"]) · $(x["when"])"), badge(source; small = true), spacer(), status(state)),
        inbox && !isempty(x["title"]) ? link(x["title"], x["url"]; cls = "cm-topic-title") : nothing,
        box("cm-reply-text", x["text"]), link("Open on $source ↗", x["url"]))
    actions = if done
        box("cm-answer", box("cm-reply-text", x["answer"]), inbox ? button("Reopen", "inbox_reopen"; id = ref, kind = "ghost") : nothing)
    elseif inbox && x["kind"] == "release"
        box("cm-row", button("Start a project", "inbox_project"; id = ref, kind = "primary"), button("Ignore", "inbox_ignore"; id = ref, kind = "ghost"))
    else
        send = inbox && x["kind"] == "topic" ? button("Copy answer", "copy"; value = x["answer"], kind = "primary", disabled = isempty(x["answer"])) :
            button("Send", inbox ? "inbox-send" : "send"; id = ref, kind = "primary")
        box("cm-section", node("textarea", "cm-textarea", x["answer"]; name = "answer", placeholder = "Your answer…"),
            box("cm-row", send, button("Save", inbox ? "inbox-save" : "save-answer"; id = ref),
                button("Ask agent", inbox ? "inbox_ask" : "ask_answer"; id = ref, kind = "ghost"), spacer(),
                inbox ? button("Done", "inbox_done"; id = ref, kind = "ghost") : nothing,
                button("Ignore", inbox ? "inbox_ignore" : "ignore"; id = ref, kind = "ghost")))
    end
    box("cm-card cm-reply" * (done ? " cm-handled" : ""), box("cm-avatar", uppercase(first(x["author_name"], 1))), box("cm-section", text, actions);
        dataBox = (inbox ? "inbox-" : "reply-") * ref, style = Styles("--plat" => get(PLATFORM_COLORS, source, "#888")))
end

function project_top(d, p)
    box("cm-section", box("cm-top", button("← Overview", "overview"; kind = "ghost"), spacer(), dropdown("state", d["states"]; selected = p["state"], dataId = p["id"])),
        box("cm-top", node("h1", "cm-h1", p["title"]; dataEditTitle = p["id"]), brand_pill.(p["brands"])...), stepper(d["states"], p["state"]))
end
function material_view(d, p)
    media = findfirst(f -> f["video"] || f["image"], p["files"])
    player = if isnothing(media)
        box("cm-empty", "No material yet: put it into $(d["folder"])/$(p["id"])")
    else
        f = p["files"][media]
        box("cm-player", f["video"] ? node("video", ""; src = f["url"], controls = true, preload = "metadata", playsinline = true) : node("img", ""; src = f["url"], alt = f["name"]))
    end
    box("cm-card cm-panel", label("Material"), player, box("cm-files", [node("span", "cm-file", f["name"]) for f in p["files"]]...))
end
function brief_view(p)
    links = [node("input", "cm-input"; type = "url", value = get(p["links"], k, ""), placeholder = "$k URL",
                  dataSave = "link:$k", dataId = p["id"], dataSaved = get(p["links"], k, "")) for k in ("youtube", "blog")]
    box("cm-card cm-panel", label("Brief"), node("textarea", "cm-textarea", p["brief"]; dataSave = "brief", dataId = p["id"], dataSaved = p["brief"]), label("Links"), box("cm-form-grid", links...))
end
function draft_text(text)
    content = Any[]; start = firstindex(text)
    for m in eachmatch(r"\{youtube_url\}|\{blog_url\}", text)
        m.offset > start && push!(content, text[start:prevind(text, m.offset)])
        push!(content, node("span", "cm-link-chip", m.match == "{youtube_url}" ? "▶ YouTube link" : "✎ Blog link"))
        start = m.offset + ncodeunits(m.match)
    end
    start <= lastindex(text) && push!(content, text[start:end])
    content
end
function draft_card(x, ui)
    id = x["id"]; state = x["status"]
    out = state in ("publishing", "published")
    body = box("cm-draft-body", isempty(x["title"]) ? nothing : box("cm-draft-title", x["title"]),
        box("cm-draft-text", draft_text(x["text"])...; dataRaw = x["text"], dataEditable = out ? nothing : true),
        node("progress", "cm-meter"; value = x["chars"], max = x["max"], title = "$(x["chars"]) of $(x["max"]) characters"),
        box("cm-files", [node("span", "cm-file", f) for f in x["media"]]...),
        isempty(x["note"]) ? nothing : box("cm-callout", state == "changes" ? "Changes asked: " * x["note"] : x["note"]),
        box("cm-posted", [link("↗ " * p["url"], p["url"]) for p in x["posts"]]...), stats(x["stats"]))
    foot = if ui["changing"] == id || ui["marking"] == id
        changes = ui["changing"] == id
        box("cm-row", input(changes ? "note" : "url", changes ? "What should change?" : "Link to the post"),
            button(changes ? "Send" : "Mark published", changes ? "changes" : "mark"; id, kind = "primary"), button("Cancel", "cancel"; kind = "ghost"); dataBox = (changes ? "changes-" : "mark-") * string(id))
    elseif state in ("draft", "changes")
        box("cm-row", button("Approve", "approve"; num = id, kind = "primary"), button("Request changes", "changes-open"; id), button("Edit", "edit"; id, kind = "ghost"), spacer(), button("Remove", "remove"; num = id, kind = "ghost"))
    elseif state == "approved"
        automatic = if x["publishes"]
            why = !isempty(x["needs_links"]) ? "Set the project's $(join(x["needs_links"], " and ")) link first" : !x["has_account"] ? "Add a $(x["platform"]) account for $(x["brand"]) in the overview" : ""
            box("cm-row", button("Publish", "publish"; num = id, kind = "primary", disabled = !isempty(why)), hint(why))
        else
            parts = split(x["final_text"], "\n---\n"; limit = 2)
            text = x["platform"] == "discourse" && !isempty(x["title"]) ? x["title"] * "\n\n" * parts[1] : parts[1]
            box("cm-row", button("Copy text", "copy"; value = strip(text), kind = "primary"), length(parts) > 1 ? button("Copy comment", "copy"; value = strip(parts[2])) : nothing, button("Mark published", "mark-open"; id))
        end
        box("cm-row", automatic, spacer(), button("Back to draft", "unapprove"; num = id, kind = "ghost"))
    elseif state == "failed"
        box("cm-row", button("Retry", "retry"; num = id, kind = "primary"), button("Edit", "edit"; id))
    else
        hint(state == "publishing" ? "Publishing…" : "Published")
    end
    box("cm-card cm-draft", box("cm-draft-head", badge(x["platform"]), box("cm-draft-who", node("span", "cm-draft-name", x["platform"]), node("span", "cm-draft-meta", "$(x["brand"]) · $(x["kind"]) · #$id · $(x["updated"])")), status(state)), body, box("cm-draft-foot", foot); dataDraft = id, style = Styles("--plat" => PLATFORM_COLORS[x["platform"]]))
end

in_filter(f, x) = f == "all" || (f == "review" ? x["status"] in ("draft", "changes", "failed") : f == "approved" ? x["status"] in ("approved", "publishing") : x["status"] == f)

function dashboard_dom(session, d)
    cache = Dict{String,CommunityRegion}()
    lists = Dict{String,Observable{Vector{CommunityRegion}}}()
    r(key, payload, build) = region!(cache, key, payload, build)
    function list(key, values, identity, render)
        obs = get!(lists, key) do
            Observable(CommunityRegion[])
        end
        items = [r("$key/$(identity(x))", x, () -> render(x)) for x in values]
        obs[] == items || (obs[] = items)
        return Bonito.KeyedList(obs; key = x -> x.key)
    end
    # Construct collection containers once. Their KeyedLists keep surviving
    # widget instances and only insert/remove/move changed identities.
    data = dashboard_data(d, d.app.state[], d.app.notice[])
    keys = data["mode"] == "overview" ? ("top", "notice", "new", "accounts", "brands", "inbox", "grid") : ("top", "notice", "hero", "drafts", "replies")
    regions = [r(k, nothing, () -> DOM.div(; hidden = true)) for k in keys]
    function update()
        data = dashboard_data(d, d.app.state[], d.app.notice[]); ui = d.ui[]
        r("notice", data["notice"], () -> isempty(data["notice"]) ? DOM.div(; hidden = true) : box("cm-notice", data["notice"]))
        if data["mode"] == "overview"
            ps = data["projects"]
            r("top", [length(ps), length(data["accounts"])], () -> box("cm-top", box("", node("h1", "cm-h1", "Community"), box("cm-sub", "$(length(ps)) projects")), spacer(), button("Accounts ($(length(data["accounts"])))", "toggle-accounts"), button("Brands", "toggle-brands"), button("Rescan", "rescan"; kind = "ghost"), button("New project", "toggle-new"; kind = "primary")))
            r("brands", [ui["showBrands"], data["brand_details"]], () -> ui["showBrands"] ? brands_view(data) : DOM.div(; hidden=true))
            r("new", [ui["showNew"], data["brand_details"]], () -> ui["showNew"] ? new_project_view(data) : DOM.div(; hidden = true))
            r("accounts", [ui["showAccounts"], data["vault_set"], data["accounts"], data["youtube_url"], data["brand_details"]], () -> ui["showAccounts"] ? accounts_view(data) : DOM.div(; hidden = true))
            messages = filter(x -> ui["showHandled"] || x["status"] in ("new", "drafted"), data["inbox"])
            inbox_list = list("inbox-items", messages, x -> x["ref"], x -> message_card(x; inbox = true))
            r("inbox", [isempty(messages), ui["showHandled"]], () -> box("cm-section", box("cm-section-head", label("Inbox"), spacer(), button("Check updates", "check-updates"; kind = "ghost"), button("Handled", "toggle-handled"; kind = "ghost"), button("Draft answers", "inbox_ask_all")), isempty(messages) ? box("cm-empty", "Nothing new. Mentions, forum topics and releases show up here.") : box("cm-replies", inbox_list)))
            projects_list = list("project-items", ps, x -> x["id"], x -> project_card_view(data, x))
            r("grid", "constant", () -> box("cm-section", label("Projects"), box("cm-grid", projects_list, button("+ New project", "toggle-new"))))
        else
            p = data["project"]
            r("top", [p["title"], p["state"], p["brands"]], () -> project_top(data, p))
            media = r("material", p["files"], () -> material_view(data, p))
            brief = r("brief", [p["brief"], p["links"]], () -> brief_view(p))
            r("hero", "constant", () -> box("cm-hero", media, brief))
            drafts = filter(x -> in_filter(ui["filter"], x), p["drafts"])
            # Each card includes only its own expanded form state.
            cards = [merge(x, Dict("marking" => ui["marking"] == x["id"], "changing" => ui["changing"] == x["id"])) for x in drafts]
            draft_list = list("draft-items", cards, x -> x["id"], x -> draft_card(x, Dict("marking" => x["marking"] ? x["id"] : nothing, "changing" => x["changing"] ? x["id"] : nothing)))
            draft_header = r("draft-header", [ui["filter"], [x["status"] for x in p["drafts"]]], () -> box("cm-section-head", label("Drafts"), box("cm-filters", [button(title, "filter"; value = k) for (k, title) in (("all", "All"), ("review", "To review"), ("approved", "Approved"), ("published", "Published"))]...),
                button("Approve all", "approve_all"; id = p["id"]), button("Publish approved automatic posts", "publish-all"; id = p["id"], kind = "primary", disabled = !any(x -> x["status"] == "approved" && x["publishes"], p["drafts"]))))
            r("drafts", "constant", () -> box("cm-section", draft_header, box("cm-drafts", draft_list)))
            reply_list = list("reply-items", p["replies"], x -> x["ref"], message_card)
            r("replies", isempty(p["replies"]), () -> box("cm-section", box("cm-section-head", label("Replies"), button("Draft answers", "ask_answers")), box("cm-replies", reply_list)))
        end
    end
    update()
    onany((args...) -> update(), session, d.app.state, d.app.notice, d.ui)
    on(session.on_close) do _
        foreach(close, values(cache))
    end
    # Root identity and the browser controller survive every region update.
    box("cm-dash", box("cm-toast", ""; hidden = true, role = "alert"), regions...)
end
