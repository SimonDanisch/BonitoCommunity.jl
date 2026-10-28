// The Community app's dashboard (BonitoCommunity.jl `Dashboard`). The server
// sends what to show as data (`data`, mode "overview" or "project") and gets the
// user's actions back on one channel (`act`, as [action, id, value]);
// `feedback` carries what couldn't be done. This module owns the DOM between.
//
// The page is drawn in regions, each redrawn only when its own data changed, so
// a playing video or a half-typed answer survives the updates around it.

export function connect(root, data, act, feedback, navigate) {
    const send = (name, id = null, value = null) => act.notify([name, id, value]);
    const ui = {filter: 'all', showNew: false, showAccounts: false, showHandled: false, marking: null, changing: null};
    const regions = new Map();      // key -> {node, sig}
    let current = data.value;
    let deferred = false;

    const toast = el('div', 'cm-toast', {role: 'alert', title: 'Click to close'});
    toast.hidden = true;
    toast.addEventListener('click', () => { toast.hidden = true; });
    feedback.on(msg => {
        if (!msg) return;
        toast.textContent = msg;
        toast.hidden = false;
        clearTimeout(toast._t);
        toast._t = setTimeout(() => { toast.hidden = true; }, 8000);
    });

    // Google's consent page opens in a tab taken at the click (a tab opened later, when the
    // server answers, would be stopped by the popup blocker).
    navigate.on(url => {
        if (!url) return;
        if (ui.loginTab && !ui.loginTab.closed) ui.loginTab.location.href = url;
        else window.open(url, '_blank', 'noopener');
        ui.loginTab = null;
    });
    feedback.on(msg => { if (msg && ui.loginTab) { ui.loginTab.close(); ui.loginTab = null; } });

    const render = () => {
        deferred = false;
        const spec = current.mode === 'overview' ? overviewRegions(current, ui)
                   : current.mode === 'project' ? projectRegions(current, ui)
                   : [['missing', '', () => [el('div', 'cm-empty', {}, `This project (${current.project_id}) is gone.`)]]];
        if (!regions.size) root.replaceChildren(toast, ...spec.map(([key]) => {
            const node = el('div', 'cm-region', {'data-region': key});
            regions.set(key, {node, sig: null});
            return node;
        }));
        for (const [key, sig, build] of spec) {
            const r = regions.get(key);
            if (!r || r.sig === sig) continue;
            const a = document.activeElement;
            const inside = a && r.node.contains(a);
            // Text being edited in place can't be rebuilt under the cursor: that region waits for the blur.
            if (inside && a.isContentEditable) { deferred = true; continue; }
            const kept = inside && a.matches('textarea, input') ? {at: focusKey(a), value: a.value, start: a.selectionStart, end: a.selectionEnd} : null;
            r.node.replaceChildren(...build());
            r.sig = sig;
            // An input the user is typing in comes back with what they typed, focused where they were.
            const b = kept && kept.at && r.node.querySelector(kept.at);
            if (b) {
                b.value = kept.value;
                b.focus();
                if (b.tagName === 'TEXTAREA' || ['text', 'search', 'password'].includes(b.type)) b.setSelectionRange(kept.start, kept.end);
            }
        }
    };
    const rerender = () => { for (const r of regions.values()) r.sig = null; render(); };
    data.on(value => { current = value; render(); });
    root.addEventListener('focusout', () => setTimeout(() => deferred && render(), 0));
    render();

    // ── what the user does ─────────────────────────────────────────────────
    root.addEventListener('click', e => {
        const b = e.target.closest('[data-act]');
        if (!b || b.disabled) return;
        e.stopPropagation();
        const a = b.dataset.act, id = b.dataset.id ?? null, num = id === null ? null : Number(id);
        const box = b.closest('[data-box]');
        switch (a) {
            case 'toggle-new': ui.showNew = !ui.showNew; ui.showAccounts = false; return rerender();
            case 'toggle-accounts': ui.showAccounts = !ui.showAccounts; ui.showNew = false; return rerender();
            case 'toggle-handled': ui.showHandled = !ui.showHandled; return rerender();
            case 'inbox-save': return send('inbox_answer', id, box.querySelector('[name=answer]').value);
            case 'inbox-send': {
                const text = box.querySelector('[name=answer]').value.trim();
                if (!text) return;
                send('inbox_answer', id, text);
                return send('inbox_send', id);
            }
            case 'filter': ui.filter = b.dataset.value; return rerender();
            case 'create': {
                const title = box.querySelector('[name=title]').value.trim();
                if (!title) return box.querySelector('[name=title]').focus();
                send('new', null, {title, brands: checked(box), brief: box.querySelector('[name=brief]').value});
                ui.showNew = false;
                return rerender();
            }
            case 'google-client': {
                const v = name => box.querySelector(`[name=${name}]`).value.trim();
                return send('google_client', null, {client_id: v('client_id'), client_secret: v('client_secret')});
            }
            case 'add-meta': {
                const token = box.querySelector('[name=page_token]');
                send('add_meta', null, {brand: box.querySelector('[name=meta_brand]').value, token: token.value.trim()});
                token.value = '';
                return;
            }
            case 'connect-youtube':
                ui.loginTab = window.open('', '_blank');
                return send('connect_youtube', null, box.querySelector('[name=yt_brand]').value);
            case 'add-account': {
                const v = name => box.querySelector(`[name=${name}]`).value.trim();
                send('add_account', null, {platform: v('platform'), brand: v('brand'), role: v('role'),
                                           handle: v('handle'), server: v('server'), secret: v('secret')});
                box.querySelector('[name=secret]').value = '';
                return;
            }
            case 'brand': {
                b.classList.toggle('cm-on');
                const group = b.closest('[data-brands]');
                if (group.dataset.brands) send('brands', group.dataset.brands, checked(group));
                return;
            }
            case 'mark-open': ui.marking = num; return rerender();
            case 'mark': {
                const url = box.querySelector('[name=url]').value.trim();
                if (url) { send('mark', num, url); ui.marking = null; }
                return;
            }
            case 'changes-open': ui.changing = num; rerender();
            return root.querySelector(`[data-box="changes-${num}"] [name=note]`)?.focus();
            case 'changes': {
                const note = box.querySelector('[name=note]').value.trim();
                if (note) { send('changes', num, note); ui.changing = null; }
                return;
            }
            case 'cancel': ui.marking = ui.changing = null; return rerender();
            case 'edit': return editText(root.querySelector(`[data-draft="${num}"] .cm-draft-text`), num, send);
            case 'copy': return navigator.clipboard.writeText(b.dataset.value);
            case 'save-answer': return send('answer', id, box.querySelector('[name=answer]').value);
            case 'send': {
                const text = box.querySelector('[name=answer]').value.trim();
                if (!text) return;
                send('answer', id, text);
                return send('send', id);
            }
            case 'open-card': return b.dataset.chat ? send('open', b.dataset.chat) : null;
            default:
                return send(a, b.dataset.num !== undefined ? Number(b.dataset.num) : id, b.dataset.value ?? null);
        }
    });
    root.addEventListener('change', e => {
        const t = e.target;
        if (t.matches('[name=state]')) send('state', t.dataset.id, t.value);
    });
    // The brief and the link save when they are left (or on Enter, for the link).
    root.addEventListener('focusout', e => {
        const t = e.target;
        if (t.dataset.save && t.value !== t.dataset.saved) {
            t.dataset.saved = t.value;
            if (t.dataset.save.startsWith('link:')) send('link', t.dataset.id, {key: t.dataset.save.slice(5), url: t.value.trim()});
            else send(t.dataset.save, t.dataset.id, t.value);
        }
    });
    root.addEventListener('keydown', e => {
        const t = e.target;
        if (e.key === 'Enter' && t.matches('input[data-save]')) t.blur();
        if (e.key === 'Enter' && t.matches('[data-box^="mark-"] input')) t.closest('[data-box]').querySelector('[data-act=mark]').click();
        if (e.key === 'Enter' && !e.shiftKey && t.matches('[data-box^="changes-"] input')) t.closest('[data-box]').querySelector('[data-act=changes]').click();
        if (e.key === 'Escape' && (ui.marking !== null || ui.changing !== null)) { ui.marking = ui.changing = null; rerender(); }
    });
    root.addEventListener('dblclick', e => {
        const text = e.target.closest('.cm-draft-text[data-editable]');
        if (text) return editText(text, Number(text.closest('[data-draft]').dataset.draft), send);
        const title = e.target.closest('[data-edit-title]');
        if (title) editTitle(title, send);
    });
}

// ── helpers ─────────────────────────────────────────────────────────────────

// How to find an input again after its region was rebuilt.
function focusKey(n) {
    const box = n.closest('[data-box]');
    if (box && n.name) return `[data-box="${box.dataset.box}"] [name="${n.name}"]`;
    if (n.dataset.save) return `[data-save="${n.dataset.save}"][data-id="${n.dataset.id}"]`;
    return null;
}
const checked = node => [...node.querySelectorAll('.cm-brand-toggle.cm-on')].map(b => b.dataset.value);
const sig = x => JSON.stringify(x);

function el(tag, className, attrs = {}, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    for (const [k, v] of Object.entries(attrs)) if (v !== undefined && v !== null && v !== false) node.setAttribute(k, v === true ? '' : v);
    if (text !== undefined) node.textContent = text;
    return node;
}
const div = (cls, ...kids) => { const d = el('div', cls); d.append(...kids.filter(k => k !== null && k !== undefined)); return d; };

function btn(label, kind, act, attrs = {}) {
    const b = el('button', `bt-btn bt-btn-sm ${kind}`, {type: 'button', 'data-act': act, ...attrs}, label);
    return b;
}

function svg(path, viewBox = '0 0 24 24') {
    const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    s.setAttribute('viewBox', viewBox); s.setAttribute('width', '14'); s.setAttribute('height', '14');
    s.innerHTML = path;
    return s;
}

// A platform's badge: its colour and a glyph.
const GLYPHS = {
    youtube: () => svg('<path fill="#fff" d="M9 7.2v9.6l7.8-4.8z"/>'),
    instagram: () => svg('<rect x="4" y="4" width="16" height="16" rx="5" fill="none" stroke="#fff" stroke-width="2"/><circle cx="12" cy="12" r="3.6" fill="none" stroke="#fff" stroke-width="2"/><circle cx="16.9" cy="7.1" r="1.2" fill="#fff"/>'),
    bluesky: () => svg('<path fill="#fff" d="M6.3 4.6c2.1 1.6 4.4 4.8 5.7 6.5 1.3-1.7 3.6-4.9 5.7-6.5 1.5-1.1 4-2 4 .8 0 .6-.3 4.7-.5 5.4-.7 2.4-3.1 3-5.3 2.6 3.8.7 4.8 2.8 2.7 5-4 4-5.7-1-6.2-2.3l-.4-1-.4 1c-.5 1.3-2.2 6.3-6.2 2.3-2.1-2.2-1.1-4.3 2.7-5-2.2.4-4.6-.2-5.3-2.6-.2-.7-.5-4.8-.5-5.4 0-2.8 2.5-1.9 4-.8z"/>'),
    tiktok: () => '♪', facebook: () => 'f', mastodon: () => 'm', linkedin: () => 'in', discourse: () => 'D', github: () => 'GH',
};
function platformBadge(platforms, id, small = false) {
    const p = platforms.find(p => p.id === id) || {color: '#888', name: id};
    const b = el('span', 'cm-plat' + (small ? ' cm-plat-sm' : ''), {title: p.name, style: `--plat:${p.color}`});
    b.append(GLYPHS[id] ? GLYPHS[id]() : id[0].toUpperCase());
    return b;
}
const platformName = (platforms, id) => (platforms.find(p => p.id === id) || {name: id}).name;
const platformColor = (platforms, id) => (platforms.find(p => p.id === id) || {color: '#888'}).color;

// Counts as people read them: 1234 → 1.2k.
const count = n => n >= 1e6 ? (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1).replace(/\.0$/, '') + 'k' : String(n);
const STAT_LABELS = [['views', 'views'], ['likes', 'likes'], ['reposts', 'reposts'], ['replies', 'replies']];
function statsRow(stats) {
    const parts = STAT_LABELS.filter(([k]) => stats && stats[k]).map(([k, label]) => `${count(stats[k])} ${label}`);
    return parts.length ? el('div', 'cm-stats', {}, parts.join(' · ')) : null;
}

const BRAND_COLORS = {Makie: '#e05a7a', Bonito: '#2f9e8f', Makie4Science: '#3a7fc4'};
function brandPill(name) {
    return el('span', 'cm-pill cm-pill-dot', {style: `--dot:${BRAND_COLORS[name] || 'var(--bt-accent)'}`}, name);
}
function brandToggles(brands, on, projectId) {
    const box = el('div', 'cm-row', {'data-brands': projectId || ''});
    for (const name of brands) {
        const b = el('button', 'cm-pill cm-pill-dot cm-brand-toggle' + (on.includes(name) ? ' cm-on' : ''),
                     {type: 'button', 'data-act': 'brand', 'data-value': name, style: `--dot:${BRAND_COLORS[name] || 'var(--bt-accent)'}`}, name);
        box.append(b);
    }
    return box;
}

function steps(states, state, labeled = false) {
    const now = states.indexOf(state);
    const box = el('div', 'cm-steps' + (labeled ? ' cm-steps-labeled' : ''), {title: `State: ${state}`});
    states.forEach((s, i) => {
        const bar = el('div', 'cm-step' + (i < now ? ' cm-step-done' : i === now ? ' cm-step-now' : ''));
        if (!labeled) return box.append(bar);
        box.append(div('cm-step-wrap', bar, el('span', 'cm-step-label' + (i === now ? ' cm-step-label-now' : ''), {}, s)));
    });
    return box;
}

function cover(card) {
    const box = el('div', 'cm-cover');
    const c = card.cover;
    if (c && c.video) box.append(el('video', '', {src: c.url + '#t=2', preload: 'metadata', muted: true, playsinline: true}));
    else if (c && c.image) box.append(el('img', '', {src: c.url, alt: '', loading: 'lazy'}));
    else box.append(el('span', 'cm-cover-letter', {}, card.title.slice(0, 1).toUpperCase()));
    return box;
}

// Edit a draft's text in place: the raw text (with the link placeholder); leaving saves, Escape keeps.
function editText(node, id, send) {
    if (!node || node.isContentEditable) return;
    const before = node.dataset.raw;
    node.textContent = before;
    node.contentEditable = 'plaintext-only';
    node.focus();
    const finish = save => {
        node.removeEventListener('keydown', key);
        node.removeEventListener('blur', blur);
        node.contentEditable = 'false';
        const now = node.textContent.trim();
        if (save && now && now !== before) send('edit', id, now);
        else node.replaceChildren(...linkified(before));
    };
    const key = k => { if (k.key === 'Escape') { k.preventDefault(); finish(false); } };
    const blur = () => finish(true);
    node.addEventListener('keydown', key);
    node.addEventListener('blur', blur);
}

// Rename a project in place: Enter or leaving saves, Escape keeps the old title.
function editTitle(node, send) {
    if (node.isContentEditable) return;
    const before = node.textContent;
    node.contentEditable = 'plaintext-only';
    node.focus();
    const finish = save => {
        node.removeEventListener('keydown', key);
        node.removeEventListener('blur', blur);
        node.contentEditable = 'false';
        const now = node.textContent.trim();
        if (save && now && now !== before) send('title', node.dataset.editTitle, now);
        else node.textContent = before;
    };
    const key = k => {
        if (k.key === 'Enter') { k.preventDefault(); finish(true); }
        else if (k.key === 'Escape') { k.preventDefault(); finish(false); }
    };
    const blur = () => finish(true);
    node.addEventListener('keydown', key);
    node.addEventListener('blur', blur);
}

// The text with the link placeholders shown as chips.
const CHIPS = {'{youtube_url}': ['▶ YouTube link', "The project's YouTube link, filled in when it is published"],
               '{blog_url}': ['✎ Blog link', "The project's blog post, filled in when it is published"]};
function linkified(text) {
    return text.split(/(\{youtube_url\}|\{blog_url\})/).map(part =>
        CHIPS[part] ? el('span', 'cm-link-chip', {title: CHIPS[part][1]}, CHIPS[part][0]) : document.createTextNode(part));
}

// ── the overview ────────────────────────────────────────────────────────────

function overviewRegions(d, ui) {
    const p = d.projects;
    const review = p.reduce((n, x) => n + x.counts.review, 0), replies = p.reduce((n, x) => n + x.new_replies, 0);
    return [
        ['top', sig([p.length, review, replies, ui.showNew, ui.showAccounts, d.accounts.length]), () => {
            const top = div('cm-top',
                div('', el('h1', 'cm-h1', {}, 'Community'),
                    el('div', 'cm-sub', {}, [`${p.length} project${p.length === 1 ? '' : 's'}`,
                        review ? `${review} draft${review === 1 ? '' : 's'} to review` : '',
                        replies ? `${replies} new repl${replies === 1 ? 'y' : 'ies'}` : ''].filter(Boolean).join(' · '))),
                el('div', 'cm-spacer'),
                btn(`Accounts${d.accounts.length ? ` (${d.accounts.length})` : ''}`, ui.showAccounts ? 'bt-btn-secondary cm-filter-on' : 'bt-btn-secondary', 'toggle-accounts'),
                btn('Rescan', 'bt-btn-ghost', 'rescan', {title: 'Pick up folders added to the projects folder'}),
                btn('New project', 'bt-btn-primary', 'toggle-new'));
            return [top];
        }],
        ['notice', sig(d.notice), () => d.notice ? [el('div', 'cm-notice', {}, d.notice)] : []],
        ['new', sig([ui.showNew, d.brands]), () => ui.showNew ? [newProject(d)] : []],
        ['accounts', sig([ui.showAccounts, d.accounts]), () => ui.showAccounts ? [accounts(d)] : []],
        ['inbox', sig([d.inbox, ui.showHandled, d.watches]), () => [inboxSection(d, ui)]],
        ['grid', sig([p, d.states]), () => [div('cm-section', div('cm-section-head', el('div', 'cm-h2', {}, 'Projects')), projectGrid(d))]],
    ];
}

function newProject(d) {
    const box = el('div', 'cm-card cm-panel', {'data-box': 'new'});
    box.append(el('div', 'cm-h2', {}, 'New project'),
        el('input', 'cm-input', {name: 'title', type: 'text', placeholder: 'Title, e.g. "Black hole render"', autocomplete: 'off'}),
        brandToggles(d.brands, []),
        el('textarea', 'cm-textarea', {name: 'brief', placeholder: 'Brief: what it is about, what the posts should say'}),
        el('div', 'cm-hint', {}, `Creates a folder in ${d.folder}; put the video and other material there.`),
        div('cm-row', btn('Create project', 'bt-btn-primary', 'create'), btn('Cancel', 'bt-btn-ghost', 'toggle-new')));
    return box;
}

const SERVER_HINT = {bluesky: 'https://bsky.social (default)', mastodon: 'from the handle, e.g. https://fosstodon.org'};
const SECRET_HINT = {
    bluesky: 'Bluesky: Settings → Privacy and security → App passwords. Never your real password.',
    mastodon: 'Mastodon: Preferences → Development → New application, scopes read and write; paste its access token.',
};

// Kept deliberately brief: this is the checklist someone needs while setting a
// platform up, not a second copy of each platform's developer documentation.
function setupGuide() {
    const step = (name, text) => div('cm-setup-step', el('strong', '', {}, name), el('span', '', {}, text));
    return div('cm-setup',
        el('div', 'cm-h2', {}, 'Set up an account'),
        step('Bluesky', 'Create an app password in Settings → Privacy and security; add your handle and that password below.'),
        step('Mastodon', 'Create an app in Preferences → Development with read + write scopes; add its access token below.'),
        step('YouTube', 'Create a Google Cloud Desktop OAuth client with YouTube Data API v3, save it below, then connect the channel.'),
        step('Facebook + Instagram', 'Create a long-lived Facebook Page token with the listed permissions; the linked Instagram account is found automatically.'),
        step('TikTok + LinkedIn', 'No credentials needed: copy an approved draft, post it there, then paste its published link back here.'));
}

function accounts(d) {
    const box = el('div', 'cm-card cm-panel', {'data-box': 'accounts'});
    const list = el('div', 'cm-accounts');
    for (const a of d.accounts) {
        list.append(div('cm-account', platformBadge(d.platforms, a.platform, true),
            el('span', 'cm-account-handle', {title: a.server}, '@' + a.handle),
            a.brand ? brandPill(a.brand) : el('span', 'cm-pill', {}, 'personal'),
            el('span', 'cm-pill', {}, a.role === 'post' ? 'posts' : 'reposts'),
            btn('Remove', 'bt-btn-ghost', 'remove_account', {'data-id': a.id})));
    }
    if (!d.accounts.length) list.append(el('div', 'cm-empty', {}, 'No accounts yet. The app publishes to Bluesky and Mastodon with them; the other platforms are posted by hand.'));
    const select = (name, options) => {
        const s = el('select', 'cm-select', {name});
        for (const [v, label] of options) s.append(el('option', '', {value: v}, label));
        return s;
    };
    const field = (label, input) => { const f = el('label', 'cm-field'); f.append(label, input); return f; };
    const platform = select('platform', d.platforms.filter(p => p.publishes && p.id !== 'youtube').map(p => [p.id, p.name]));
    const server = el('input', 'cm-input', {name: 'server', type: 'text', placeholder: SERVER_HINT[platform.value]});
    const hint = el('div', 'cm-hint', {}, SECRET_HINT[platform.value]);
    platform.addEventListener('change', () => { server.placeholder = SERVER_HINT[platform.value]; hint.textContent = SECRET_HINT[platform.value]; });
    const form = div('cm-form-grid',
        field('Platform', platform),
        field('Brand', select('brand', [...d.brands.map(b => [b, b]), ['', 'Personal']])),
        field('Role', select('role', [['post', "Posts the brand's drafts"], ['amplify', 'Reposts them']])),
        field('Handle', el('input', 'cm-input', {name: 'handle', type: 'text', placeholder: 'makie.org · makie@fosstodon.org', autocomplete: 'off'})),
        field('Server', server),
        field('App password / token', el('input', 'cm-input', {name: 'secret', type: 'password', autocomplete: 'new-password'})));
    box.append(el('div', 'cm-h2', {}, 'Accounts'), list, setupGuide(), el('div', 'cm-h2', {}, 'Add a Bluesky or Mastodon account'), form, hint,
        div('cm-row', btn('Check and add', 'bt-btn-primary', 'add-account'), btn('Close', 'bt-btn-ghost', 'toggle-accounts')),
        el('div', 'cm-hint', {}, 'Each brand has one posting account per platform; every other account on that platform reposts what it publishes.'),
        youtubeAccounts(d, select, field), metaAccounts(d, select, field));
    return box;
}

function inboxSection(d, ui) {
    const open = d.inbox.filter(x => x.status === 'new' || x.status === 'drafted');
    const handled = d.inbox.length - open.length;
    const head = div('cm-section-head', el('div', 'cm-h2', {}, 'Inbox'),
        el('span', 'cm-sub', {}, open.length ? `${open.length} open` : ''), el('span', 'cm-spacer'),
        handled ? el('button', 'cm-filter' + (ui.showHandled ? ' cm-filter-on' : ''), {type: 'button', 'data-act': 'toggle-handled'},
                     `Handled ${handled}`) : null,
        open.length ? btn('Draft answers', 'bt-btn-secondary', 'inbox_ask_all', {title: "Ask the overview's agent to draft answers to the open items"}) : null);
    const shown = ui.showHandled ? d.inbox : open;
    if (!shown.length) {
        return div('cm-section', head, el('div', 'cm-empty', {}, 'Nothing new. Mentions of the accounts, new forum topics and new releases ' +
            `show up here (watching ${d.watches.length} source${d.watches.length === 1 ? '' : 's'}).`));
    }
    const list = el('div', 'cm-replies');
    for (const x of shown) list.append(inboxCard(d, x));
    return div('cm-section', head, list);
}

function inboxCard(d, x) {
    const done = !['new', 'drafted'].includes(x.status);
    const card = el('div', 'cm-card cm-reply' + (done ? ' cm-handled' : ''),
                    {style: `--plat:${platformColor(d.sources, x.source)}`, 'data-box': `inbox-${x.ref}`});
    const avatar = el('div', 'cm-avatar', {}, (x.author_name || x.author || '?').slice(0, 1).toUpperCase());
    const main = el('div', 'cm-section');
    main.style.gap = '6px';
    main.append(div('cm-row', el('strong', '', {}, x.author_name || x.author), el('span', 'cm-sub', {}, `@${x.author} · ${x.when}`),
            platformBadge(d.sources, x.source, true), x.brand ? brandPill(x.brand) : null, el('span', 'cm-spacer'),
            el('span', `cm-status cm-status-${x.status}`, {}, x.status === 'new' && x.kind !== 'mention' ? x.kind : x.status)));
    if (x.title) main.append(el('a', 'cm-topic-title', {href: x.url, target: '_blank', rel: 'noopener'}, x.title));
    main.append(el('div', 'cm-reply-text', {}, x.text),
        el('a', 'cm-sub', {href: x.url, target: '_blank', rel: 'noopener'}, 'Open on ' + platformName(d.sources, x.source) + ' ↗'));
    if (done) {
        if (x.answer) main.append(div('cm-answer', el('div', 'cm-sub', {}, x.status === 'answered' ? 'Answered:' : 'Drafted:'),
                                      el('div', 'cm-reply-text', {}, x.answer)));
        main.append(div('cm-row', btn('Reopen', 'bt-btn-ghost', 'inbox_reopen', {'data-id': x.ref})));
    } else if (x.kind === 'release') {
        main.append(div('cm-row',
            btn('Start a project', 'bt-btn-primary', 'inbox_project', {'data-id': x.ref, title: 'A project for its blog post and the announcements'}),
            el('span', 'cm-spacer'), btn('Ignore', 'bt-btn-ghost', 'inbox_ignore', {'data-id': x.ref})));
    } else {
        const answer = el('textarea', 'cm-textarea', {name: 'answer', placeholder: x.kind === 'topic' ? 'An answer for the forum…' : 'Your answer…'});
        answer.value = x.answer;
        answer.style.minHeight = '60px';
        const send = x.kind === 'mention'
            ? btn('Send', 'bt-btn-primary', 'inbox-send', {'data-id': x.ref, title: 'Send this answer now'})
            : btn('Copy answer', 'bt-btn-primary', 'copy', {'data-value': x.answer, disabled: !x.answer, title: 'Copy it, then answer on the forum'});
        main.append(answer, div('cm-row', send,
            btn('Save', 'bt-btn-secondary', 'inbox-save', {'data-id': x.ref}),
            btn('Ask agent', 'bt-btn-ghost', 'inbox_ask', {'data-id': x.ref, title: "Ask the overview's agent to draft it"}),
            el('span', 'cm-spacer'),
            btn('Done', 'bt-btn-ghost', 'inbox_done', {'data-id': x.ref, title: 'Nothing (more) to do'}),
            btn('Ignore', 'bt-btn-ghost', 'inbox_ignore', {'data-id': x.ref})));
    }
    card.append(avatar, main);
    return card;
}

function youtubeAccounts(d, select, field) {
    const box = el('div', 'cm-section', {'data-box': 'youtube'});
    box.append(div('cm-row', platformBadge(d.platforms, 'youtube', true), el('div', 'cm-h2', {}, 'YouTube')));
    if (!d.google_client) {
        box.append(el('div', 'cm-hint', {}, 'Once: in Google Cloud, create a project, enable the YouTube Data API v3, set the OAuth ' +
                                          'consent screen to "In production", then create an OAuth client of type "Desktop app" and paste it here.'),
            div('cm-form-grid',
                field('OAuth client id', el('input', 'cm-input', {name: 'client_id', type: 'text', placeholder: '….apps.googleusercontent.com', autocomplete: 'off'})),
                field('OAuth client secret', el('input', 'cm-input', {name: 'client_secret', type: 'password', autocomplete: 'new-password'}))),
            div('cm-row', btn('Save client', 'bt-btn-primary', 'google-client')));
        return box;
    }
    box.append(div('cm-row', field('Channel for', select('yt_brand', d.youtube_brands.map(b => [b, b]))),
            btn('Connect channel', 'bt-btn-primary', 'connect-youtube', {style: 'align-self:flex-end'})),
        el('div', 'cm-hint', {}, `Opens Google's login in a new tab: pick the brand's channel (not your own). ` +
            `Uploads start as ${d.youtube_privacy}` + (d.youtube_privacy === 'private' ? ' until Google has audited the API project; switch them to public in YouTube Studio.' : '.')));
    return box;
}

function metaAccounts(d, select, field) {
    const box = el('div', 'cm-section', {'data-box': 'meta'});
    box.append(div('cm-row', platformBadge(d.platforms, 'facebook', true), platformBadge(d.platforms, 'instagram', true),
                   el('div', 'cm-h2', {}, 'Facebook Page and Instagram')),
        el('div', 'cm-hint', {}, "A long-lived access token of the brand's Facebook Page (Meta for Developers → Graph API Explorer, " +
            'permissions pages_manage_posts, pages_read_engagement, instagram_basic, instagram_content_publish, ' +
            'instagram_manage_comments). It also finds the Instagram account linked to the Page.'),
        div('cm-form-grid', field('For', select('meta_brand', d.meta_brands.map(b => [b, b]))),
            field('Page access token', el('input', 'cm-input', {name: 'page_token', type: 'password', autocomplete: 'new-password'}))),
        div('cm-row', btn('Check and add', 'bt-btn-primary', 'add-meta')),
        el('div', 'cm-hint', {}, 'TikTok and LinkedIn are posted by hand: approved drafts there get "Copy text" and "Mark published".'));
    return box;
}

function projectGrid(d) {
    const grid = el('div', 'cm-grid');
    for (const p of d.projects) grid.append(projectCard(d, p));
    const add = el('button', 'cm-card cm-new-card', {type: 'button', 'data-act': 'toggle-new'}, '+ New project');
    grid.append(add);
    return grid;
}

function projectCard(d, p) {
    const card = el('div', 'cm-card cm-project', {'data-act': 'open-card', 'data-chat': p.chat || undefined,
                                                   title: p.chat ? 'Open the project' : undefined});
    const c = cover(p);
    if (p.new_replies) c.append(div('cm-cover-badge', el('span', 'cm-status cm-status-new', {}, `${p.new_replies} new repl${p.new_replies === 1 ? 'y' : 'ies'}`)));
    const counts = p.counts;
    const summary = [counts.review && `${counts.review} to review`, counts.approved && `${counts.approved} approved`,
                     counts.published && `${counts.published} published`, counts.failed && `${counts.failed} failed`].filter(Boolean);
    const plats = el('div', 'cm-plats');
    for (const id of p.platforms) plats.append(platformBadge(d.platforms, id, true));
    const body = div('cm-project-body',
        div('cm-row', el('div', 'cm-project-title', p.chat ? {} : {'data-edit-title': p.id, title: 'Double-click to rename'}, p.title),
            el('span', 'cm-spacer'), el('span', 'cm-status', {}, p.state)),
        steps(d.states, p.state));
    if (p.chat) {
        body.append(div('cm-row', ...p.brands.map(brandPill)),
                    div('cm-row', el('span', 'cm-sub', {}, summary.join(' · ') || `${p.nfiles} file${p.nfiles === 1 ? '' : 's'}, no drafts yet`),
                        el('span', 'cm-spacer'), plats));
        const stats = statsRow(p.stats);
        if (stats) body.append(stats);
    } else {
        // Not started yet: its brands and the start, right here.
        body.append(...[brandToggles(d.brands, p.brands, p.id),
            p.brief ? el('div', 'cm-sub', {}, p.brief) : null,
            div('cm-row', el('span', 'cm-sub', {}, `${p.nfiles} file${p.nfiles === 1 ? '' : 's'}`), el('span', 'cm-spacer'),
                btn('Start drafting', 'bt-btn-primary', 'start', {'data-id': p.id, disabled: p.brands.length === 0,
                    title: p.brands.length ? "Ask the overview's agent to start this project's chat" : 'Pick its brands first'}))].filter(Boolean));
    }
    card.append(c, body);
    return card;
}

// ── a project ───────────────────────────────────────────────────────────────

function projectRegions(d, ui) {
    const p = d.project;
    const drafts = p.drafts;
    return [
        ['top', sig([p.title, p.state, p.brands, d.states]), () => [projectTop(d, p)]],
        ['notice', sig(d.notice), () => d.notice ? [el('div', 'cm-notice', {}, d.notice)] : []],
        ['hero', sig([p.files.map(f => f.name), p.brief, p.links, d.folder]), () => [projectHero(d, p)]],
        ['drafts', sig([drafts, ui.filter, ui.marking, ui.changing, p.links]), () => [draftSection(d, p, ui)]],
        ['replies', sig(p.replies), () => [replySection(d, p)]],
    ];
}

function projectTop(d, p) {
    const state = el('select', 'cm-select', {name: 'state', 'data-id': p.id, style: 'width:auto', title: 'Move the project to another state'});
    for (const s of d.states) { const o = el('option', '', {value: s}, s); o.selected = s === p.state; state.append(o); }
    return div('cm-section',
        div('cm-top', btn('← Overview', 'bt-btn-ghost', 'overview'), el('span', 'cm-spacer'), state),
        div('cm-top', el('h1', 'cm-h1', {'data-edit-title': p.id, title: 'Double-click to rename'}, p.title), ...p.brands.map(brandPill)),
        steps(d.states, p.state, true));
}

function projectHero(d, p) {
    const media = p.files.find(f => f.video) || p.files.find(f => f.image);
    const left = el('div', 'cm-card cm-panel');
    left.append(el('div', 'cm-h2', {}, 'Material'));
    if (media) {
        const player = el('div', 'cm-player');
        player.append(media.video ? el('video', '', {src: media.url, controls: true, preload: 'metadata', playsinline: true})
                                  : el('img', '', {src: media.url, alt: media.name}));
        left.append(player);
    }
    if (p.files.length) {
        const files = el('div', 'cm-files');
        for (const f of p.files) files.append(el('span', 'cm-file', {title: f.name}, f.name));
        left.append(files);
    } else left.append(el('div', 'cm-empty', {}, `No material yet: put it into ${d.folder}/${p.id}`));

    const right = el('div', 'cm-card cm-panel');
    const brief = el('textarea', 'cm-textarea', {'data-save': 'brief', 'data-id': p.id, 'data-saved': p.brief,
                                                  placeholder: 'What it is about, what the posts should say'});
    brief.value = p.brief;
    const linkInput = (key, placeholder) => {
        const v = p.links[key] || '';
        const input = el('input', 'cm-input', {type: 'url', 'data-save': 'link:' + key, 'data-id': p.id, 'data-saved': v, placeholder});
        input.value = v;
        return input;
    };
    right.append(el('div', 'cm-h2', {}, 'Brief'), brief,
        el('div', 'cm-h2', {}, 'Links'),
        div('cm-form-grid', linkInput('youtube', 'YouTube video: https://youtu.be/…'), linkInput('blog', 'Blog post: https://makie.org/…')),
        el('div', 'cm-hint', {}, 'Filled into the drafts that link to them. Publishing the YouTube video sets its link.'));
    return div('cm-hero', left, right);
}

const FILTERS = [['all', 'All'], ['review', 'To review'], ['approved', 'Approved'], ['published', 'Published']];
const inFilter = (f, x) => f === 'all' || (f === 'review' ? ['draft', 'changes', 'failed'].includes(x.status)
                                        : f === 'approved' ? ['approved', 'publishing'].includes(x.status) : x.status === f);

function draftSection(d, p, ui) {
    const drafts = p.drafts.filter(x => inFilter(ui.filter, x));
    const toApprove = p.drafts.filter(x => x.status === 'draft').length;
    const filters = el('div', 'cm-filters');
    for (const [k, label] of FILTERS) {
        const n = p.drafts.filter(x => inFilter(k, x)).length;
        filters.append(el('button', 'cm-filter' + (ui.filter === k ? ' cm-filter-on' : ''), {type: 'button', 'data-act': 'filter', 'data-value': k}, `${label} ${n}`));
    }
    const head = div('cm-section-head', el('div', 'cm-h2', {}, 'Drafts'), filters, el('span', 'cm-spacer'),
        toApprove ? btn(`Approve all (${toApprove})`, 'bt-btn-secondary', 'approve_all', {'data-id': p.id}) : null);
    const grid = el('div', 'cm-drafts');
    // Grouped by platform, in the platforms' order.
    const order = d.platforms.map(x => x.id);
    drafts.sort((a, b) => order.indexOf(a.platform) - order.indexOf(b.platform) || a.id - b.id);
    for (const x of drafts) grid.append(draftCard(d, p, x, ui));
    const empty = !p.drafts.length ? el('div', 'cm-empty', {}, 'No drafts yet: the project chat writes them. Ask it in the chat beside this.')
                : !drafts.length ? el('div', 'cm-empty', {}, 'None here.') : null;
    return div('cm-section', head, empty || grid);
}

function draftCard(d, p, x, ui) {
    const color = platformColor(d.platforms, x.platform);
    const card = el('div', 'cm-card cm-draft', {'data-draft': x.id, style: `--plat:${color}`});
    card.append(div('cm-draft-head', platformBadge(d.platforms, x.platform),
        div('cm-draft-who', el('span', 'cm-draft-name', {}, platformName(d.platforms, x.platform)),
            el('span', 'cm-draft-meta', {}, `${x.brand} · ${x.kind} · #${x.id} · ${x.updated}`)),
        el('span', `cm-status cm-status-${x.status}`, {}, x.status)));

    const body = el('div', 'cm-draft-body');
    if (x.title) body.append(el('div', 'cm-draft-title', {}, x.title));
    const out = ['publishing', 'published'].includes(x.status);
    const text = el('div', 'cm-draft-text', {'data-raw': x.text, 'data-editable': out ? undefined : true,
                                              title: out ? undefined : 'Double-click to edit'});
    text.append(...linkified(x.text));
    body.append(text);
    const ratio = x.chars / x.max;
    const meter = el('div', 'cm-meter' + (ratio > 1 ? ' cm-meter-over' : ratio > 0.9 ? ' cm-meter-warn' : ''), {title: `${x.chars} of ${x.max} characters`});
    meter.append(el('div', '', {style: `width:${Math.min(100, ratio * 100).toFixed(1)}%`}));
    body.append(meter);
    if (x.media.length) { const f = el('div', 'cm-files'); for (const m of x.media) f.append(el('span', 'cm-file', {}, m)); body.append(f); }
    if (x.note) body.append(el('div', 'cm-callout' + (x.status === 'published' ? ' cm-callout-info' : ''), {},
        x.status === 'changes' ? `Changes asked: ${x.note}` : x.note));
    if (x.posts.length) {
        const posted = el('div', 'cm-posted');
        const original = x.posts.find(q => q.kind === 'original');
        if (original) { const a = el('a', '', {href: original.url, target: '_blank', rel: 'noopener'}, '↗ ' + original.url); posted.append(a); }
        const reposts = x.posts.filter(q => q.kind === 'repost').length;
        if (reposts) posted.append(el('span', 'cm-sub', {}, `reposted by ${reposts} account${reposts === 1 ? '' : 's'}`));
        const stats = statsRow(x.stats);
        if (stats) posted.append(stats);
        body.append(posted);
    }
    card.append(body);

    const foot = el('div', 'cm-draft-foot');
    if (ui.changing === x.id) {
        const box = div('cm-row', el('input', 'cm-input', {name: 'note', type: 'text', placeholder: 'What should change? (Enter sends it to the project chat)'}),
            btn('Send', 'bt-btn-primary', 'changes', {'data-id': x.id}), btn('Cancel', 'bt-btn-ghost', 'cancel'));
        box.setAttribute('data-box', `changes-${x.id}`); box.style.width = '100%';
        foot.append(box);
    } else if (ui.marking === x.id) {
        const box = div('cm-row', el('input', 'cm-input', {name: 'url', type: 'url', placeholder: 'Link to the post'}),
            btn('Mark published', 'bt-btn-primary', 'mark', {'data-id': x.id}), btn('Cancel', 'bt-btn-ghost', 'cancel'));
        box.setAttribute('data-box', `mark-${x.id}`); box.style.width = '100%';
        foot.append(box);
    } else if (x.status === 'draft' || x.status === 'changes') {
        foot.append(btn('Approve', 'bt-btn-primary', 'approve', {'data-num': x.id}),
                    btn('Request changes', 'bt-btn-secondary', 'changes-open', {'data-id': x.id}),
                    btn('Edit', 'bt-btn-ghost', 'edit', {'data-id': x.id}), el('span', 'cm-spacer'),
                    btn('Remove', 'bt-btn-ghost', 'remove', {'data-num': x.id}));
    } else if (x.status === 'approved') {
        if (x.publishes) {
            const why = x.needs_links.length ? `Set the project's ${x.needs_links.join(' and ')} link first`
                      : !x.has_account ? `No ${platformName(d.platforms, x.platform)} account posts for ${x.brand}: add one in the overview` : '';
            foot.append(btn('Publish', 'bt-btn-primary', 'publish', {'data-num': x.id, disabled: !!why, title: why || 'Publish now, then repost with the other accounts'}));
            if (why) foot.append(el('span', 'cm-hint', {}, why));
        } else {
            const [post, comment] = x.final_text.split(/\n---\n/);
            foot.append(btn('Copy text', 'bt-btn-primary', 'copy', {'data-value': post.trim(), title: `Copy, then post it on ${platformName(d.platforms, x.platform)}`}));
            if (comment) foot.append(btn('Copy comment', 'bt-btn-secondary', 'copy', {'data-value': comment.trim()}));
            foot.append(btn('Mark published', 'bt-btn-secondary', 'mark-open', {'data-id': x.id}));
        }
        foot.append(el('span', 'cm-spacer'), btn('Back to draft', 'bt-btn-ghost', 'unapprove', {'data-num': x.id}));
    } else if (x.status === 'publishing') {
        foot.append(el('span', 'cm-sub', {}, 'Publishing…'));
    } else if (x.status === 'failed') {
        foot.append(btn('Retry', 'bt-btn-primary', 'retry', {'data-num': x.id}), btn('Edit', 'bt-btn-ghost', 'edit', {'data-id': x.id}));
    } else if (x.status === 'published') {
        const original = x.posts.find(q => q.kind === 'original');
        if (original) foot.append(el('a', 'bt-btn bt-btn-sm bt-btn-secondary', {href: original.url, target: '_blank', rel: 'noopener'}, 'View post'));
    }
    card.append(foot);
    return card;
}

function replySection(d, p) {
    const open = p.replies.filter(r => r.status === 'new' || r.status === 'drafted');
    const head = div('cm-section-head', el('div', 'cm-h2', {}, 'Replies'),
        el('span', 'cm-sub', {}, p.replies.length ? `${open.length} open of ${p.replies.length}` : ''), el('span', 'cm-spacer'),
        open.length ? btn('Draft answers', 'bt-btn-secondary', 'ask_answers', {title: "Ask this project's agent to draft answers to the open replies"}) : null);
    if (!p.replies.length) return div('cm-section', head, el('div', 'cm-empty', {}, 'Replies to the published Bluesky and Mastodon posts show up here.'));
    const list = el('div', 'cm-replies');
    for (const r of p.replies) list.append(replyCard(d, r));
    return div('cm-section', head, list);
}

function replyCard(d, r) {
    const card = el('div', 'cm-card cm-reply', {style: `--plat:${platformColor(d.platforms, r.platform)}`, 'data-box': `reply-${r.ref}`});
    const avatar = el('div', 'cm-avatar', {}, (r.author_name || r.author).slice(0, 1).toUpperCase());
    const main = el('div', 'cm-section');
    main.style.gap = '6px';
    main.append(div('cm-row', el('strong', '', {}, r.author_name), el('span', 'cm-sub', {}, `@${r.author} · ${r.when}`),
            platformBadge(d.platforms, r.platform, true), el('span', 'cm-spacer'),
            el('span', `cm-status cm-status-${r.status}`, {}, r.status)),
        el('div', 'cm-reply-text', {}, r.text),
        el('a', 'cm-sub', {href: r.url, target: '_blank', rel: 'noopener'}, 'View on ' + platformName(d.platforms, r.platform) + ' ↗'));
    if (r.status === 'answered') {
        main.append(div('cm-answer', el('div', 'cm-sub', {}, 'Answered:'), el('div', 'cm-reply-text', {}, r.answer)));
    } else if (r.status !== 'ignored') {
        const answer = el('textarea', 'cm-textarea', {name: 'answer', placeholder: 'Your answer…'});
        answer.value = r.answer;
        answer.style.minHeight = '60px';
        main.append(answer, div('cm-row',
            btn('Send', 'bt-btn-primary', 'send', {'data-id': r.ref, title: 'Send this answer now'}),
            btn('Save', 'bt-btn-secondary', 'save-answer', {'data-id': r.ref}),
            btn('Ask agent', 'bt-btn-ghost', 'ask_answer', {'data-id': r.ref, title: "Ask this project's agent to draft it"}),
            el('span', 'cm-spacer'), btn('Ignore', 'bt-btn-ghost', 'ignore', {'data-id': r.ref})));
    }
    card.append(avatar, main);
    return card;
}
