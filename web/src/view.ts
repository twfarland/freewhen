// Every screen, as pure functions from state to a template. Nothing here
// touches the DOM, reads a global, or knows a socket exists.
//
// One screen asks for one thing, and which thing is the room's phase — the
// server works that out and this only reads it. Collecting asks everyone when
// they are free; ready asks the host to choose; a decided meeting is the date,
// with the grid still open underneath it because plans change.

import { html, nothing } from 'lit'
import type { TemplateResult } from 'lit'
import { gridView } from './grid.ts'
import type { Paint } from './grid.ts'
import { asClock } from './hours.ts'
import type { Hours } from './hours.ts'
import type { Preset } from './mask.ts'
import type { Proposal, Room } from './protocol.ts'
import type { Status } from './socket.ts'
import { brief, span } from './time.ts'

export type State = {
  hash: string | undefined
  isHost: boolean
  status: Status
  notice: string
  busy: boolean
  room: Room | undefined
  mine: Uint8Array | undefined
  joined: boolean
  /** This browser's own alias, which is how it finds itself in the list. */
  alias: string | undefined
  hours: Hours
  /** The host has seen the link and moved on from it. */
  sent: boolean
  /** The host has asked to call the meeting off and not yet confirmed. */
  callingOff: boolean
}

export type Actions = {
  create: (form: HTMLFormElement) => void
  sent: () => void
  join: (alias: string) => void
  preset: (kind: Preset) => void
  paint: Paint
  pick: (slot: number) => void
  unpick: () => void
  excludeSilent: () => void
  askCallOff: () => void
  keepIt: () => void
  callOff: () => void
  copyLink: () => void
  addToCalendar: () => void
}

export function app(state: State, actions: Actions): TemplateResult {
  if (state.hash === undefined) return start(state, actions)
  return html`${bar(state, actions)}${room(state, actions)}`
}

// ---------- starting one ----------

function start(state: State, actions: Actions): TemplateResult {
  return html`
    ${bar(state, actions)}
    <form
      class="single"
      @submit=${(event: SubmitEvent) => {
        event.preventDefault()
        actions.create(event.target as HTMLFormElement)
      }}
    >
      <h1>When can everyone meet?</h1>
      <p class="lede">
        Send one link. Everyone marks when they are free, and everyone sees how many people
        are free in each slot — never who.
      </p>
      <div class="actions">
        <button class="primary" type="submit" ?disabled=${state.busy}>Start a meeting</button>
      </div>
      <p class="tuning">
        ${select('duration', ['30 minutes', '1 hour', '15 minutes', '90 minutes'], [30, 60, 15, 90])}
        over the next ${select('days', ['7 days', '3 days', '14 days'], [7, 3, 14])}
      </p>
      <p class="status" role="status">${state.notice}</p>
    </form>
  `
}

function select(name: string, labels: string[], values: number[]): TemplateResult {
  return html`<select name=${name}>
    ${labels.map((label, index) => html`<option value=${values[index] ?? 0}>${label}</option>`)}
  </select>`
}

// ---------- the room ----------

function bar(state: State, actions: Actions): TemplateResult {
  // Nothing to copy once the room has gone: offering the address of a meeting
  // that was called off is an invitation to a 404.
  const showLink = state.hash !== undefined && state.sent && state.room !== undefined
  return html`
    <div class="bar">
      <span class="wordmark">FreeWhen</span>
      ${showLink
        ? html`<span class="linkbox">
            <span class="link">${link(state)}</span>
            <button class="quiet" type="button" @click=${actions.copyLink}>Copy link</button>
          </span>`
        : nothing}
    </div>
  `
}

function link(state: State): string {
  return `${location.origin}/m/#${state.hash ?? ''}`
}

function room(state: State, actions: Actions): TemplateResult {
  if (state.room === undefined) {
    return html`<p class="single status" role="status">
      ${state.notice || 'Opening the meeting…'}
    </p>`
  }
  if (state.isHost && !state.sent) return sendLink(state, actions)
  if (!state.joined) return whoAreYou(state, actions)
  return planning(state.room, state, actions)
}

// The host's first job, and the only one on screen while they do it: this
// meeting is worth nothing until the other people have the address.
function sendLink(state: State, actions: Actions): TemplateResult {
  return html`
    <div class="single">
      <h1>Send this to everyone.</h1>
      <p class="share">${link(state)}</p>
      <div class="actions">
        <button class="primary" type="button" @click=${actions.copyLink}>Copy link</button>
        <button class="quiet" type="button" @click=${actions.sent}>Sent it — next</button>
      </div>
    </div>
  `
}

function whoAreYou(state: State, actions: Actions): TemplateResult {
  return html`
    <form
      class="single"
      @submit=${(event: SubmitEvent) => {
        event.preventDefault()
        const alias = new FormData(event.target as HTMLFormElement).get('alias')
        if (typeof alias === 'string' && alias.trim() !== '') actions.join(alias.trim())
      }}
    >
      <h1>What should the others call you?</h1>
      <input name="alias" maxlength="32" placeholder="Your name" required autofocus />
      <div class="actions">
        <button class="primary" type="submit">Continue</button>
      </div>
      <p class="status" role="status">${state.notice}</p>
    </form>
  `
}

function planning(room: Room, state: State, actions: Actions): TemplateResult {
  return html`
    ${head(room, state, actions)}
    <div class="room">
      <div class="rail">
        <section>
          <h2>Who is here</h2>
          ${attendees(room, state.alias)}${goAhead(room, state, actions)}
        </section>
        ${state.status === 'open' ? nothing : html`<p class="fineprint">Reconnecting…</p>`}
        ${callingOff(state, actions)}
      </div>
      <div>
        ${room.phase === 'collecting' ? nothing : html`<h2>Your availability</h2>`}
        ${presets(state, actions)}
        ${gridView(room, state.mine ?? new Uint8Array(), state.hours, actions.paint)}
      </div>
    </div>
  `
}

// ---------- one head per phase ----------

function head(room: Room, state: State, actions: Actions): TemplateResult {
  if (room.chosen !== null) return decided(room.chosen, room, state, actions)
  if (room.phase === 'ready') return ready(room, state, actions)
  return html`
    <div class="head">
      <h1>When are you free?</h1>
      <p class="lede">Drag down a column. Shading is how many are free, never who.</p>
      <p class="status" role="status">${state.notice}</p>
    </div>
  `
}

// Everybody has answered, so the job stops being answering and becomes
// choosing — and only one person can do that.
function ready(room: Room, state: State, actions: Actions): TemplateResult {
  return html`
    <div class="head">
      <h1>Everyone has answered.</h1>
      ${state.isHost
        ? html`<p class="lede">Pick a time.</p>
            ${times(room, actions, true)}`
        : html`<p class="lede">Waiting for a time to be chosen.</p>`}
      <p class="status" role="status">${state.notice}</p>
    </div>
  `
}

// A time is on the table. Confirmed means every single person here is free for
// all of it; on the table means somebody is not — either the host chose it
// knowing that, or somebody's plans changed since.
function decided(chosen: Proposal, room: Room, state: State, actions: Actions): TemplateResult {
  const settled = room.phase === 'confirmed'
  return html`
    <div class="head settled">
      <h2>${settled ? 'The meeting is at' : 'On the table'}</h2>
      <p class="when">${span(chosen.startsAt, chosen.endsAt)}</p>
      ${settled ? nothing : shortfall(chosen, room, state)}
      <div class="actions">
        <button
          class=${settled ? 'primary' : 'quiet'}
          type="button"
          @click=${actions.addToCalendar}
        >
          Add to calendar
        </button>
        ${state.isHost
          ? html`<button class="quiet" type="button" @click=${actions.unpick}>
              Plans changed — move it
            </button>`
          : nothing}
      </div>
      ${state.isHost && !settled ? times(room, actions, false) : nothing}
      <p class="status" role="status">${state.notice}</p>
    </div>
  `
}

function shortfall(chosen: Proposal, room: Room, state: State): TemplateResult {
  return html`<p class="unsolved">
    <strong>Only ${chosen.free} of ${room.attendees.length} can make this.</strong>
    ${state.isHost
      ? 'Choose another time below, or go ahead without them.'
      : 'If that is you, change your availability and it will show here.'}
  </p>`
}

// ---------- the rail ----------

function attendees(room: Room, you: string | undefined): TemplateResult {
  if (room.attendees.length === 0) return html`<p class="fineprint">Nobody yet.</p>`
  return html`
    <ul>
      ${room.attendees.map(
        (attendee) => html`
          <li class="${attendee.ready ? '' : 'waiting'} ${attendee.alias === you ? 'you' : ''}">
            ${attendee.alias}${attendee.ready ? nothing : ' — waiting'}
          </li>
        `,
      )}
    </ul>
  `
}

// The only way past the gate, and it appears only when there is a gate to get
// past: somebody opened the link and never said anything.
function goAhead(room: Room, state: State, actions: Actions): TemplateResult | typeof nothing {
  const silent = room.attendees.filter((attendee) => !attendee.ready).length
  if (!state.isHost || silent === 0) return nothing
  return html`<button class="quiet spaced" type="button" @click=${actions.excludeSilent}>
    Go ahead without ${silent === 1 ? 'them' : 'the rest'}
  </button>`
}

// Two steps, because it deletes the meeting for everybody at once. "Call off"
// rather than "cancel", so that cancelling a cancellation is not a sentence
// anybody has to parse.
function callingOff(state: State, actions: Actions): TemplateResult | typeof nothing {
  if (!state.isHost) return nothing
  if (!state.callingOff) {
    return html`<section class="calloff">
      <button class="quiet" type="button" @click=${actions.askCallOff}>
        Call this meeting off
      </button>
    </section>`
  }
  return html`<section class="calloff">
    <p class="fineprint">This deletes it for everyone, at once.</p>
    <div class="actions">
      <button class="primary" type="button" @click=${actions.callOff}>Yes, call it off</button>
      <button class="quiet" type="button" @click=${actions.keepIt}>Never mind</button>
    </div>
  </section>`
}

// ---------- answering ----------

function presets(state: State, actions: Actions): TemplateResult {
  const { start, end } = state.hours
  return html`
    <div class="actions presets">
      <button type="button" @click=${() => actions.preset('weekdays')}>
        Weekdays ${asClock(start)}–${asClock(end)}
      </button>
      <button class="quiet" type="button" @click=${() => actions.preset('always')}>Any time</button>
      <button class="quiet" type="button" @click=${() => actions.preset('never')}>Clear</button>
    </div>
  `
}

// ---------- times to choose from ----------

// Only ever shown to the host, and only when choosing is the job: a ranked
// list nobody can act on is a list nobody should have to read.
function times(room: Room, actions: Actions, warn: boolean): TemplateResult {
  if (room.proposals.length === 0) {
    return html`<p class="unsolved">There is no time when anyone at all is free.</p>`
  }
  const everyone = room.attendees.length
  const best = room.proposals[0]?.free ?? 0
  return html`
    ${warn && best < everyone
      ? html`<p class="unsolved">
          <strong>No time works for all ${everyone}.</strong> The best any slot manages is
          ${best}. Somebody has to move, or the meeting goes ahead without them.
        </p>`
      : nothing}
    <ul class="proposals">
      ${room.proposals.map((proposal) => option(proposal, everyone, room, actions))}
    </ul>
  `
}

function option(proposal: Proposal, everyone: number, room: Room, actions: Actions): TemplateResult {
  const already = room.chosen?.slot === proposal.slot
  return html`<li class=${proposal.free === everyone ? 'all' : 'partial'}>
    <button type="button" ?disabled=${already} @click=${() => actions.pick(proposal.slot)}>
      ${brief(proposal.startsAt)}<span class="free">${proposal.free}/${everyone}</span>
    </button>
  </li>`
}
