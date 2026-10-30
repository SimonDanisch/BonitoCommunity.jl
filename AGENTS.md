# Community UI

Follow Bonito's widget architecture (Bonito.jl/AGENTS.md):

- Build structure in Julia with `DOM`, `Styles` and `CSS`. Views live in
  `src/views.jl`; do not add a parallel JavaScript renderer.
- `Dashboard` owns explicit per-tab observable state. Domain state belongs to
  `CommunityApp`. Wire render-time listeners to the Bonito session.
- Use cached item widgets and `Bonito.KeyedList` for project, draft and reply
  collections. Keep media separate from brief and link updates.
- The ES6 `DashboardController` receives its root/dialog nodes and observable
  channels from Julia. Keep JavaScript limited to browser interactions.
- Theme variables and button classes belong to Community. Never depend on
  BonitoAgents' internal CSS classes or theme variables.
- Run the browser walkthrough after UI changes, including first-use PIN setup,
  per-platform review, and preservation of unrelated cards and media nodes.
  Confirm the eval session loaded the edited code; restart if Revise is absent.
