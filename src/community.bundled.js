// deno-fmt-ignore-file
// deno-lint-ignore-file
// This code was bundled using `deno bundle` and it's not recommended to edit it manually

class DashboardController {
    constructor(root, dialog, pinOpen, actions, feedback, uiState, layout, layoutKey){
        this.root = root;
        this.dialog = dialog;
        this.pinOpen = pinOpen;
        this.actions = actions;
        const redirect = ()=>root.querySelectorAll('[data-youtube-redirect]').forEach((n)=>n.value = location.origin + '/community-youtube-callback');
        redirect();
        this.redirectObserver = new MutationObserver(redirect);
        this.redirectObserver.observe(root, {
            childList: true,
            subtree: true
        });
        this.ui = {
            showNew: false,
            showAccounts: false,
            showHandled: false,
            showBrands: false
        };
        uiState.on((state)=>Object.assign(this.ui, state));
        const serializeLayout = (value)=>JSON.stringify(value, (_key, item)=>ArrayBuffer.isView(item) ? Array.from(item) : item);
        const defaults = JSON.parse(serializeLayout(layout.value));
        this.resetLayout = ()=>layout.notify(structuredClone(defaults));
        const mobile = window.matchMedia('(max-width: 700px)');
        const storageKey = ()=>layoutKey + (mobile.matches ? '-mobile' : '');
        const panelIds = (tree)=>tree.type === 'tabs' ? tree.panels : tree.children.flatMap(panelIds);
        const expected = panelIds(defaults.root).sort();
        const restoreLayout = ()=>{
            let next = structuredClone(defaults);
            try {
                const saved = JSON.parse(localStorage.getItem(storageKey()) || 'null');
                if (saved) {
                    const ids = [
                        ...panelIds(saved.root),
                        ...saved.floating.map((x)=>x.panel)
                    ].sort();
                    if (JSON.stringify(ids) === JSON.stringify(expected)) next = saved;
                }
            } catch (error) {
                console.warn('Could not restore Community layout', error);
            }
            layout.notify(next);
        };
        restoreLayout();
        mobile.addEventListener('change', ()=>requestAnimationFrame(restoreLayout));
        layout.on((value)=>{
            try {
                localStorage.setItem(storageKey(), serializeLayout(value));
            } catch (error) {
                console.warn('Could not save Community layout', error);
            }
        });
        root.addEventListener('click', (e)=>this.click(e));
        root.addEventListener('change', (e)=>{
            if (e.target.matches('[name=state]')) this.send('state', e.target.dataset.id, e.target.value);
            if (e.target.matches('[name=project_chat]')) this.send('open', e.target.value);
        });
        root.addEventListener('focusout', (e)=>this.save(e.target));
        root.addEventListener('keydown', (e)=>{
            if (e.key === 'Enter' && e.target.matches('input[data-save]')) e.target.blur();
            if (e.key === 'Enter' && e.target.closest('[data-box^="mark-"], [data-box^="changes-"]')) {
                e.preventDefault();
                e.target.closest('[data-box]').querySelector('button').click();
            }
        });
        root.addEventListener('dblclick', (e)=>{
            const n = e.target.closest('[data-edit-title], .cm-draft-text[data-editable]');
            if (n) this.edit(n);
        });
        dialog.addEventListener('click', (e)=>{
            const act = e.target.closest('[data-act]')?.dataset.act;
            if (act === 'pin-cancel') this.closePin(null);
            if (act === 'pin-submit') this.submitPin();
        });
        dialog.addEventListener('submit', (e)=>{
            e.preventDefault();
            this.submitPin();
        });
        dialog.addEventListener('keydown', (e)=>{
            if (e.key === 'Enter' && e.target.matches('input')) {
                e.preventDefault();
                this.submitPin();
            }
        });
        pinOpen.on((open)=>{
            if (!open) this.finishPin(null);
        });
        feedback.on((msg)=>{
            const toast = root.querySelector('.cm-toast');
            toast.textContent = msg;
            toast.hidden = !msg;
            toast.onclick = ()=>toast.hidden = true;
        });
    }
    send(action, id = null, value = null) {
        this.actions.notify([
            action,
            id,
            value
        ]);
    }
    view(patch) {
        Object.assign(this.ui, patch);
        this.send('view', null, patch);
    }
    askPin(title, confirm = false) {
        if (this.pendingPin) throw new Error('A PIN action is already pending');
        const d = this.dialog;
        const result = new Promise((resolve)=>this.pendingPin = resolve);
        const ready = ()=>{
            const first = d.querySelector('[name=pin]');
            if (!first) return;
            this.pinObserver?.disconnect();
            this.pinObserver = null;
            d.querySelector('[data-pin=title]').textContent = title;
            d.querySelector('[data-pin=error]').textContent = '';
            d.querySelector('[name=pin_confirmation]').hidden = !confirm;
            d.querySelector('[data-act=pin-submit]').textContent = confirm ? 'Set PIN' : 'Continue';
            first.focus();
        };
        this.pinObserver = new MutationObserver(ready);
        this.pinObserver.observe(d, {
            childList: true,
            subtree: true
        });
        this.pinOpen.notify(true);
        return result;
    }
    finishPin(pin) {
        this.pinObserver?.disconnect();
        this.pinObserver = null;
        this.dialog.querySelectorAll('input').forEach((n)=>n.value = '');
        const resolve = this.pendingPin;
        this.pendingPin = null;
        resolve?.(pin);
    }
    closePin(pin) {
        this.finishPin(pin);
        this.pinOpen.notify(false);
    }
    submitPin() {
        const d = this.dialog, first = d.querySelector('[name=pin]'), second = d.querySelector('[name=pin_confirmation]');
        const error = d.querySelector('[data-pin=error]');
        if (!first.value) {
            error.textContent = 'Enter the Community PIN.';
            return;
        }
        if (!second.hidden && first.value !== second.value) {
            error.textContent = 'The PINs do not match.';
            return;
        }
        this.closePin(first.value);
    }
    async pinAction(title, action, id = null, value = null) {
        const pin = await this.askPin(title);
        if (pin) this.send(action, id, value === null ? pin : {
            ...value,
            pin
        });
    }
    save(t) {
        if (!t.dataset.save || t.value === t.dataset.saved) return;
        t.dataset.saved = t.value;
        if (t.dataset.save.startsWith('link:')) this.send('link', t.dataset.id, {
            key: t.dataset.save.slice(5),
            url: t.value.trim()
        });
        else this.send(t.dataset.save, t.dataset.id, t.value);
    }
    edit(node) {
        if (node.isContentEditable) return;
        const before = node.dataset.raw ?? node.textContent, children = [
            ...node.childNodes
        ];
        node.textContent = before;
        node.contentEditable = 'plaintext-only';
        node.focus();
        const abort = new AbortController();
        const finish = (save)=>{
            abort.abort();
            node.contentEditable = 'false';
            const value = node.textContent.trim();
            if (save && value && value !== before) this.send(node.dataset.editTitle ? 'title' : 'edit', node.dataset.editTitle ?? Number(node.closest('[data-draft]').dataset.draft), value);
            else node.replaceChildren(...children);
        };
        node.addEventListener('blur', ()=>finish(true), {
            signal: abort.signal
        });
        node.addEventListener('keydown', (e)=>{
            if (e.key === 'Escape' || e.key === 'Enter' && node.dataset.editTitle) {
                e.preventDefault();
                finish(e.key === 'Enter');
            }
        }, {
            signal: abort.signal
        });
    }
    checked(node) {
        return [
            ...node.querySelectorAll('.cm-brand-toggle.cm-on')
        ].map((b)=>b.dataset.value);
    }
    click(e) {
        const b = e.target.closest('[data-act]');
        if (!b || b.disabled) return;
        e.stopPropagation();
        const a = b.dataset.act, id = b.dataset.id ?? null, num = Number(b.dataset.num ?? id), box = b.closest('[data-box]');
        switch(a){
            case 'reset-layout':
                return this.resetLayout();
            case 'toggle-brands':
                return this.view({
                    showBrands: !this.ui.showBrands,
                    showAccounts: false,
                    showNew: false
                });
            case 'save-brand':
                return this.send('save_brand', id, {
                    name: box.querySelector('[name=brand_name]').value.trim(),
                    notes: box.querySelector('[name=brand_notes]').value,
                    platforms: [
                        ...box.querySelectorAll('[name=brand_platform]:checked')
                    ].map((n)=>n.value)
                });
            case 'delete-brand':
                return this.send('delete_brand', id);
            case 'toggle-new':
                return this.view({
                    showNew: !this.ui.showNew,
                    showAccounts: false,
                    showBrands: false
                });
            case 'toggle-accounts':
                return this.view({
                    showAccounts: !this.ui.showAccounts,
                    showNew: false,
                    showBrands: false
                });
            case 'toggle-handled':
                return this.view({
                    showHandled: !this.ui.showHandled
                });
            case 'filter':
                return this.view({
                    filter: b.dataset.value
                });
            case 'mark-open':
                return this.view({
                    marking: num
                });
            case 'changes-open':
                return this.view({
                    changing: num
                });
            case 'cancel':
                return this.view({
                    marking: null,
                    changing: null
                });
            case 'create':
                {
                    const title = box.querySelector('[name=title]').value.trim();
                    const brands = this.checked(box), error = box.querySelector('[data-create-error]');
                    error.textContent = !title ? 'Enter a project title.' : !brands.length ? 'Choose at least one brand below the title.' : '';
                    error.hidden = !error.textContent;
                    if (!title) return box.querySelector('[name=title]').focus();
                    if (!brands.length) return box.querySelector('[data-act=brand]')?.focus();
                    return this.send('new', null, {
                        title,
                        brands,
                        brief: box.querySelector('[name=brief]').value
                    });
                }
            case 'brand':
                {
                    b.classList.toggle('cm-on');
                    const group = b.closest('[data-brands]');
                    if (group.dataset.brands) this.send('brands', group.dataset.brands, this.checked(group));
                    return;
                }
            case 'set-pin':
                return this.askPin('Set Community PIN', true).then((pin)=>pin && this.send('set_pin', null, pin));
            case 'check-updates':
                return this.pinAction('Check replies and mentions', 'check_updates');
            case 'remove-account':
                return this.pinAction('Remove this account?', 'remove_account', id);
            case 'publish':
                return this.pinAction('Publish this approved post?', 'publish', num);
            case 'publish-all':
                return this.pinAction('Publish all approved automatic posts?', 'publish_all', id);
            case 'reshare':
                return this.send('reshare', num, Number(box.querySelector('[name=reshare_from]').value));
            case 'add-account':
                {
                    const role = b.dataset.role, form = role === 'amplify' ? b.closest('details').querySelector('[data-account-form=amplify]') : box.querySelector('[data-account-form=post]');
                    const v = (name)=>form.querySelector(`[name=${name}]`)?.value.trim() || '';
                    const value = {
                        platform: b.dataset.platform,
                        role,
                        brand: v('brand'),
                        handle: v('handle'),
                        server: '',
                        secret: v('secret')
                    };
                    form.querySelector('[name=secret]').value = '';
                    return this.pinAction('Check and add this account', 'add_account', null, value);
                }
            case 'add-meta':
                {
                    const token = box.querySelector('[name=page_token]'), value = {
                        brand: box.querySelector('[name=meta_brand]').value,
                        token: token.value.trim()
                    };
                    token.value = '';
                    return this.pinAction('Connect Facebook and Instagram', 'add_meta', null, value);
                }
            case 'google-client':
                {
                    const secret = box.querySelector('[name=google_secret]');
                    const value = {
                        client_id: box.querySelector('[name=google_id]').value.trim(),
                        client_secret: secret.value.trim()
                    };
                    secret.value = '';
                    return this.pinAction('Encrypt Google client credentials', 'google_client', null, value);
                }
            case 'connect-youtube':
                return this.pinAction('Connect YouTube channel', 'connect_youtube', null, {
                    brand: box.querySelector('[name=youtube_brand]').value,
                    redirect: location.origin + '/community-youtube-callback'
                });
            case 'finish-youtube':
                return this.pinAction('Finish connecting YouTube', 'finish_youtube');
            case 'send':
            case 'inbox-send':
                {
                    const text = box.querySelector('[name=answer]').value.trim();
                    if (text) return this.pinAction('Send this answer?', a === 'send' ? 'send' : 'inbox_send', id, {
                        text
                    });
                    return;
                }
            case 'save-answer':
            case 'inbox-save':
                return this.send(a === 'save-answer' ? 'answer' : 'inbox_answer', id, box.querySelector('[name=answer]').value);
            case 'mark':
            case 'changes':
                {
                    const value = box.querySelector(a === 'mark' ? '[name=url]' : '[name=note]').value.trim();
                    if (value) {
                        this.send(a, num, value);
                        this.view({
                            marking: null,
                            changing: null
                        });
                    }
                    return;
                }
            case 'edit':
                return this.edit(this.root.querySelector(`[data-draft="${num}"] .cm-draft-text`));
            case 'copy':
                return navigator.clipboard.writeText(b.dataset.value);
            case 'open-card':
                if (b.dataset.chat) this.send('open', b.dataset.chat);
                return;
            default:
                return this.send(a, b.dataset.num === undefined ? id : num, b.dataset.value ?? null);
        }
    }
}
export { DashboardController as DashboardController };

