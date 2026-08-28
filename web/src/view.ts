// Every screen, as pure functions from state to a template. Nothing here
// touches the DOM, reads a global, or knows a socket exists.

import { html, nothing } from 'lit'
import type { TemplateResult } from 'lit'
import { gridView } from './grid.ts'
import type { Paint } from './grid.ts'
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
}

export type Actions = {
  create: (form: HTMLFormElement) => void
  join: (alias: string) => void
  preset: (kind: Preset) => void
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
        No account, no calendar access, nothing stored. The room deletes itself after 24 hours,
        or minutes after a time is chosen.
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
      ${shareBar(state, actions)} ${state.joined ? availability(actions) : joinForm(actions)}
      ${chosenPanel(room, state, actions)}
      <div class="panels">
        <div>
          <h2>Who is here</h2>
          ${attendees(room)}
          <p class="status" role="status">${state.notice}</p>
          <p class="fineprint">Connection: ${state.status}</p>
        </div>
        <div>
          <h2>Best times</h2>
          ${proposals(room, state, actions)}
        </div>
      </div>
      <h2>The week</h2>
      <p class="fineprint">
        Drag across the grid to mark yourself busy. Shading is how many people are free — never
        which people.
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

function availability(actions: Actions): TemplateResult {
  return html`
    <div>
      <h2>Your availability</h2>
      <p class="fineprint">Start from a preset, then drag the grid to fix the exceptions.</p>
      <div class="row">
        <button type="button" @click=${() => actions.preset('weekdays')}>
          Only weekdays 9–5
        </button>
        <button type="button" @click=${() => actions.preset('clear')}>Free all week</button>
        <button type="button" @click=${() => actions.preset('all')}>Busy all week</button>
      </div>
    </div>
  `
}

function attendees(room: Room): TemplateResult {
  if (room.attendees.length === 0) return html`<p class="fineprint">Nobody yet.</p>`
  return html`
    <ul>
      ${room.attendees.map(
        (attendee) => html`
          <li class=${attendee.ready ? '' : 'waiting'}>
            ${attendee.alias}${attendee.ready ? nothing : ' — not set yet'}
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
