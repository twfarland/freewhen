# 0007. The client renders with Lit templates

- Status: Accepted
- Date: 2026-08-28

## Context

The first client was vanilla imperative DOM. It worked, and it was already hard
to follow after a week of writing it.

The grid was the worst of it. `renderGrid` built 672 cells once, then on every
message from the server ran `querySelector('[data-slot="…"]')` 672 times and
hand-patched each cell's class list, inline style and title. Elsewhere,
`hidden` was toggled on panels from four different functions, and lists were
rebuilt with `replaceChildren` — which meant a redraw arriving mid-drag would
destroy the element the pointer was captured on.

None of that is incidental. Keeping a DOM tree in sync with a state object by
hand is precisely the problem view libraries exist to remove, and doing it
manually converts every new piece of state into a new place to forget an
update.

## Decision

The client renders with **lit-html**, via `html` and `render` from `lit`. No
`LitElement`, no custom elements, no shadow DOM, and no decorators — just
templates and one `render()` call.

The shape is a small state container: `update(patch)` merges into a `State`,
then calls `render(app(state, actions), root)`. `view.ts` and `grid.ts` are
pure functions from state to a template and touch nothing else;
`main.ts` owns the state and the side effects.

`index.html` becomes a shell — a header and `<main id="app">`.

## Consequences

Every `querySelector` is gone, along with the build-once-then-mutate lifecycle
and every manual `hidden` toggle. What a screen looks like in a given state is
readable in one place, and adding a field to `State` cannot leave a stale
corner of the DOM behind, because there is no code that updates corners.

Drag-painting got simpler *and* more correct. lit patches templates in place
rather than replacing elements, so a redraw arriving mid-gesture no longer
destroys what the pointer is on, and the 1344 per-cell event bindings collapsed
into two delegated listeners reading `data-slot`.

**It did not reduce the line count.** The client is 798 lines against 626
before, once the deleted `.ics` module is excluded from the comparison — but
about 90 lines of markup moved out of `index.html` in the process, so the true
delta is nearer +80. Anyone expecting a framework to shrink the code should
know it did not; what it bought was that the code says what it means.

The bundle went from 3 kB to 10 kB gzipped. For a page loaded once per meeting
that is not a cost worth optimising, and it is the whole price of the
dependency — lit has none of its own.

One dependency now stands between the client and the browser, in a project that
otherwise has exactly one on each side. Lit is a stable 3.x release with a
long-lived API and no build-time requirement beyond bundling, so this is a much
smaller bet than a framework with a compiler.

## Alternatives considered

**Staying vanilla.** Fewest dependencies and smallest bundle, and it is what
the code already was. Rejected on the grounds the code itself demonstrated:
672 `querySelector` calls per message is not a thing anyone should maintain.

**Preact, with `htm` to avoid a JSX build step.** Comparable size and a
familiar model. Lit wins narrowly on being closer to the platform — templates
are tagged template literals evaluated by the browser, with no virtual DOM
between the template and the elements — and on needing no compile step even in
principle.

**Solid.** Faster than either, with fine-grained updates that would suit a
672-cell grid especially well. Rejected because it needs a JSX compiler, which
is a build-time dependency this project does not otherwise have.

**`LitElement` and web components.** The fuller Lit offering. Rejected because
shadow DOM would isolate the single stylesheet for no benefit here, and
component lifecycle is machinery this app has no use for: it has one state
object and one render.
