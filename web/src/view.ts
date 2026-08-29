// Every screen, as pure functions from state to a template. Nothing here
// touches the DOM, reads a global, or knows a socket exists.

import { html, nothing } from 'lit'
import type { TemplateResult } from 'lit'
import { gridView } from './grid.ts'
import type { Paint } from './grid.ts'
import { asClock, fromClock } from './hours.ts'
import type { Hours } from './hours.ts'
import { meetingUrl } from './invite.ts'
import type { Preset } from './mask.ts'
import type { Proposal, Room } from './protocol.ts'
import type { Status } from './socket.ts'
import { span } from './time.ts'

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
}

export type Actions = {
  create: (form: HTMLFormElement) => void
  join: (alias: string) => void
  preset: (kind: Preset) => void
  setHours: (hours: Hours) => void
  paint: Paint
  pick: (slot: number) => void
  copyLink: () => void
  addToCalendar: () => void
}

export function app(state: State, actions: Actions): TemplateResult {
  return state.hash === undefined ? createView(state, actions) : roomView(state, actions)
}

// ---------- creating ----------

function createView(state: State, actions: Actions): TemplateResult {
  return html`
    <section>
      <h2>Start a room</h2>
      <form
        @submit=${(event: SubmitEvent) => {
          event.preventDefault()
          actions.create(event.target as HTMLFormElement)
        }}
      >
        <label>
          Meeting length
          <select name="duration">
            <option value="30" selected>30 minutes</option>
            <option value="60">1 hour</option>
            <option value="15">15 minutes</option>
            <option value="90">90 minutes</option>
          </select>
        </label>
        <label>
          Look ahead
          <select name="days">
            <option value="7" selected>7 days</option>
            <option value="3">3 days</option>
            <option value="14">14 days</option>
          </select>
        </label>
        <label>
          Resolution
          <select name="slotMinutes">
            <option value="30">30 minutes</option>
            <option value="15" selected>15 minutes</option>
            <option value="60">1 hour</option>
          </select>
        </label>
        <button type="submit" ?disabled=${state.busy}>Create room</button>
        <p class="status" role="status">${state.notice}</p>
      </form>
      <p class="fineprint">
        No account and no calendar access. Nothing about you outlives the room, and the room
        deletes itself once a time is chosen — or after a month with nobody touching it.
      </p>
    </section>
  `
}

// ---------- the room ----------

function roomView(state: State, actions: Actions): TemplateResult {
  const room = state.room
  if (room === undefined) {
    return html`<section>
      <p class="status" role="status">${state.notice || 'Opening the room…'}</p>
    </section>`
  }

  return html`
    <section>
      ${shareBar(state, actions)}
      ${state.joined ? availability(state, actions) : joinForm(actions)}
      ${chosenPanel(room, state, actions)}
      <div class="panels">
        <div>
          <h2>Who is here</h2>
          ${attendees(room, state.alias)}
          <p class="status" role="status">${state.notice}</p>
          ${connection(state.status)}
        </div>
        <div>
          <h2>Best times</h2>
          ${proposals(room, state, actions)}
        </div>
      </div>
      <h2>The week</h2>
      <p class="fineprint">
        Drag across the grid to mark when you are free, or move with the arrow keys and press
        space. Shading is how many people are free — never which people.
      </p>
      ${gridView(room, state.mine ?? new Uint8Array(), state.joined ? actions.paint : undefined)}
    </section>
  `
}

function shareBar(state: State, actions: Actions): TemplateResult {
  return html`
    <div class="share">
      <label for="shareLink">Send this link to the others</label>
      <div class="row">
        <input id="shareLink" type="text" readonly .value=${`${location.origin}/m/#${state.hash}`} />
        <button type="button" @click=${actions.copyLink}>Copy</button>
      </div>
    </div>
  `
}

function joinForm(actions: Actions): TemplateResult {
  return html`
    <form
      @submit=${(event: SubmitEvent) => {
        event.preventDefault()
        const alias = new FormData(event.target as HTMLFormElement).get('alias')
        if (typeof alias === 'string' && alias.trim() !== '') actions.join(alias.trim())
      }}
    >
      <label>
        Pick a name the others will recognise
        <input name="alias" maxlength="32" placeholder="Blue Falcon" required />
      </label>
      <button type="submit">Join</button>
    </form>
  `
}

// The socket reconnects by itself with backoff, so a drop is a wait rather
// than a failure — and a deploy is a two-second drop. Reporting it as "closed"
// made a routine restart look like something had gone wrong.
function connection(status: Status): TemplateResult | typeof nothing {
  if (status === 'open') return nothing
  return html`<p class="fineprint" role="status">Reconnecting…</p>`
}

function availability(state: State, actions: Actions): TemplateResult {
  const change = (edge: keyof Hours) => (event: Event) => {
    const minutes = fromClock((event.target as HTMLInputElement).value)
    if (minutes !== undefined) actions.setHours({ ...state.hours, [edge]: minutes })
  }
  const { start, end } = state.hours
  return html`
    <div>
      <h2>When are you free?</h2>
      <p class="fineprint">Start from a preset, then adjust the grid.</p>
      <div class="row">
        <button type="button" @click=${() => actions.preset('weekdays')}>
          Weekdays ${asClock(start)}–${asClock(end)}
        </button>
        <button type="button" @click=${() => actions.preset('always')}>Any time</button>
        <button type="button" @click=${() => actions.preset('never')}>Clear</button>
      </div>
      <div class="row">
        <label>
          My day starts
          <input type="time" .value=${asClock(start)} @change=${change('start')} />
        </label>
        <label>
          and ends
          <input type="time" .value=${asClock(end)} @change=${change('end')} />
        </label>
      </div>
    </div>
  `
}

function attendees(room: Room, you: string | undefined): TemplateResult {
  if (room.attendees.length === 0) return html`<p class="fineprint">Nobody yet.</p>`
  return html`
    <ul>
      ${room.attendees.map(
        (attendee) => html`
          <li class="${attendee.ready ? '' : 'waiting'} ${attendee.alias === you ? 'you' : ''}">
            ${attendee.alias}${attendee.alias === you ? html`<span class="tag">you</span>` : nothing}
            ${attendee.ready ? nothing : ' — not set yet'}
          </li>
        `,
      )}
    </ul>
  `
}

// ---------- proposals ----------

function proposals(room: Room, state: State, actions: Actions): TemplateResult {
  if (room.proposals.length === 0) {
    return html`<p class="fineprint">Nothing works for everyone yet.</p>`
  }
  const settled = room.chosen !== null
  return html`
    <ul class="proposals">
      ${room.proposals.map((proposal) => proposalItem(proposal, room, state, actions, settled))}
    </ul>
    ${state.isHost && !settled
      ? html`<p class="fineprint">You started this room, so you choose.</p>`
      : nothing}
  `
}

function proposalItem(
  proposal: Proposal,
  room: Room,
  state: State,
  actions: Actions,
  settled: boolean,
): TemplateResult {
  const label = `${span(proposal.startsAt, proposal.endsAt)} — ${proposal.free} of ${
    room.attendees.length
  } free`
  return html`<li>
    ${state.isHost && !settled
      ? html`<button type="button" @click=${() => actions.pick(proposal.slot)}>${label}</button>`
      : label}
  </li>`
}

function chosenPanel(room: Room, state: State, actions: Actions): TemplateResult | typeof nothing {
  const chosen = room.chosen
  if (chosen === null) return nothing
  const url = meetingUrl(state.hash ?? '')
  return html`
    <div class="picked">
      <h2>It is settled</h2>
      <p>${span(chosen.startsAt, chosen.endsAt)}</p>
      <p>Meet at <a href=${url} rel="noreferrer noopener">${url}</a></p>
      <button type="button" @click=${actions.addToCalendar}>Add to calendar</button>
    </div>
  `
}
