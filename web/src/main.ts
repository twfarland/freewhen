// State, actions, and one render call. Everything visual is in view.ts.
//
// The room hash lives in the URL fragment, which browsers do not send to the
// server when loading a page. The host token lives in localStorage and is
// never in a URL at all.
//
// Recovery is the people in the room handing back the pieces they were
// holding. On every connection this client resubmits what it remembers; if the
// server has never heard of this attendee, the room was rebuilt and it rejoins
// first. A host whose room has gone entirely reopens it at the same address by
// presenting its token.

import { render } from 'lit'
import { DEFAULT_HOURS, areHours } from './hours.ts'
import { download, invite } from './invite.ts'
import { decodeMask, emptyMask, encodeMask, preset as presetMask, setSlot } from './mask.ts'
import { forget, recall, remember } from './memory.ts'
import type { Memory } from './memory.ts'
import { openRoom } from './protocol.ts'
import type { Grid, RoomShape, ServerMessage } from './protocol.ts'
import { accepted, connected, errored, opened, restoring } from './session.ts'
import type { Session } from './session.ts'
import { connect } from './socket.ts'
import type { Connection } from './socket.ts'
import { app } from './view.ts'
import type { Actions, State } from './view.ts'

const SUBMIT_DEBOUNCE_MS = 250

function mount(): HTMLElement {
  const found = document.getElementById('app')
  if (found === null) throw new Error('missing #app')
  return found
}

const root = mount()
const hash = location.hash.replace(/^#/, '') || undefined

// Whether this browser has a place in the room outlives a reload, so it is
// derived from what was stored rather than assumed false. session.ts has the
// rules and the reason.
const stored = hash === undefined ? {} : recall(hash)
let session: Session = opened(stored.attendeeId)

let state: State = {
  hash,
  isHost: stored.hostToken !== undefined,
  status: 'connecting',
  notice: '',
  busy: false,
  room: undefined,
  mine: undefined,
  joined: session.joined,
  alias: stored.alias,
  // A stored preference from an older release, or a hand-edited one, must not
  // be able to produce a preset that selects nothing.
  hours: areHours(stored.hours) ? stored.hours : DEFAULT_HOURS,
  // A host who has not yet sent the link has one job, and it is that.
  sent: stored.hostToken === undefined || session.joined,
  callingOff: false,
}

let connection: Connection | undefined
let pending: number | undefined
let resuming = false

// A meeting that was called off must stay called off. The socket closing is
// otherwise indistinguishable from the server having gone away, and reopening
// is exactly the wrong thing to do: the host's own browser holds the token the
// address derives from, so it would resurrect the meeting it just deleted.
let calledOff = false

function update(patch: Partial<State>): void {
  state = { ...state, ...patch }
  render(app(state, actions), root)
}

function memory(): Memory {
  return state.hash === undefined ? {} : recall(state.hash)
}

// ---------- actions ----------

const actions: Actions = {
  create: (form) => {
    void create(form)
  },

  // Aliases are how everyone else refers to you, so two of them in one room is
  // ambiguous for the humans before it is ambiguous for the highlight below.
  // Advisory only: the server does not enforce it yet, and two people joining
  // at once can still collide.
  join: (alias) => {
    if (state.room?.attendees.some((attendee) => attendee.alias === alias) === true) {
      update({ notice: 'Somebody here is already called that — pick another name.' })
      return
    }
    if (state.hash !== undefined) remember(state.hash, { alias })
    update({ alias })
    connection?.send({ type: 'join', alias })
  },

  preset: (kind) => {
    if (state.room === undefined) return
    update({ mine: presetMask(state.room.grid, kind, state.hours) })
    submit()
  },

  paint: (slot, free) => {
    if (state.mine === undefined) return
    const mine = Uint8Array.from(state.mine)
    setSlot(mine, slot, free)
    update({ mine })
    submit()
  },

  sent: () => {
    update({ sent: true })
  },

  pick: (slot) => {
    const hostToken = memory().hostToken
    if (hostToken !== undefined) connection?.send({ type: 'pick', hostToken, slot })
  },

  unpick: () => {
    const hostToken = memory().hostToken
    if (hostToken !== undefined) connection?.send({ type: 'unpick', hostToken })
  },

  excludeSilent: () => {
    const hostToken = memory().hostToken
    if (hostToken !== undefined) connection?.send({ type: 'excludeSilent', hostToken })
  },

  askCallOff: () => {
    update({ callingOff: true })
  },

  keepIt: () => {
    update({ callingOff: false })
  },

  callOff: () => {
    const hostToken = memory().hostToken
    update({ callingOff: false })
    if (hostToken !== undefined) connection?.send({ type: 'cancel', hostToken })
  },

  copyLink: () => {
    void navigator.clipboard.writeText(`${location.origin}/m/#${state.hash ?? ''}`)
  },

  addToCalendar: () => {
    const chosen = state.room?.chosen
    if (chosen == null || state.hash === undefined) return
    download('freewhen.ics', invite(chosen.startsAt, chosen.endsAt, state.hash))
  },
}

async function create(form: HTMLFormElement): Promise<void> {
  const data = new FormData(form)
  const days = Number(data.get('days'))
  const minutes = Number(data.get('duration'))
  // Granularity follows the meeting rather than being a third question: half
  // hours unless the meeting is shorter than one, and nobody has ever wanted
  // to say when they are free to the quarter hour for an hour-long meeting.
  const slotMinutes = minutes < 30 ? 15 : 30
  const shape: RoomShape = {
    startsAt: startOfNextHour(),
    slotMinutes,
    slots: (days * 24 * 60) / slotMinutes,
    durationSlots: Math.max(1, Math.round(minutes / slotMinutes)),
  }

  update({ busy: true, notice: 'creating…' })
  try {
    const created = await openRoom(shape)
    remember(created.hash, { hostToken: created.hostToken, shape })
    location.href = `/m/#${created.hash}`
  } catch (error) {
    const notice = error instanceof Error ? error.message : 'Could not create the meeting.'
    update({ busy: false, notice })
  }
}

function startOfNextHour(): number {
  const at = new Date()
  at.setMinutes(0, 0, 0)
  at.setHours(at.getHours() + 1)
  return at.getTime()
}

/** Painting fires per cell; the socket should not. */
function submit(): void {
  if (pending !== undefined) window.clearTimeout(pending)
  pending = window.setTimeout(sendAvailability, SUBMIT_DEBOUNCE_MS)
}

function sendAvailability(): void {
  const { attendeeId } = memory()
  if (attendeeId === undefined || state.mine === undefined || state.hash === undefined) return
  const free = encodeMask(state.mine)
  remember(state.hash, { free })
  connection?.send({ type: 'submit', attendeeId, free })
}

// ---------- recovery ----------

/**
 * Reopen a room the server has forgotten.
 *
 * Only the host can: the address is derived from their token, so nobody else
 * can prove a right to it. It is idempotent, so it is safe to try whenever the
 * room seems to be missing without first working out why.
 */
async function resume(): Promise<void> {
  const { hostToken, shape } = memory()
  if (calledOff || resuming || hostToken === undefined || shape === undefined) return
  resuming = true
  update({ notice: 'The server restarted — reopening this meeting…' })
  try {
    await openRoom(shape, hostToken)
    connection?.retryNow()
  } catch {
    update({ notice: 'Could not reopen this meeting.' })
  } finally {
    resuming = false
  }
}

/** Hand back whatever this browser was holding. Once per connection. */
function restore(): void {
  const { attendeeId, free } = memory()
  if (attendeeId === undefined || free === undefined) return
  connection?.send({ type: 'submit', attendeeId, free })
}

// ---------- messages ----------

function onMessage(message: ServerMessage): void {
  switch (message.type) {
    case 'state':
      update({
        room: message.room,
        mine: state.mine ?? storedMask(message.room.grid),
        notice: '',
      })
      const owed = restoring(session)
      session = owed.session
      if (owed.resubmit) restore()
      return
    case 'joined':
      session = accepted(session)
      if (state.hash !== undefined) remember(state.hash, { attendeeId: message.attendeeId })
      update({ joined: session.joined })
      // Hand back an answer this browser was already holding, and nothing
      // else. Submitting the empty mask a fresh joiner starts with would mark
      // them as having answered the moment they arrived, which is exactly what
      // the gate on choosing a time exists to prevent.
      restore()
      return
    case 'error':
      onError(message.reason)
      return
    case 'closed':
      // Called off is not the same as lost. Nothing this browser holds is
      // worth keeping, and holding the host token would let a reload reopen
      // the very meeting that was deleted.
      if (message.reason === 'cancelled') {
        calledOff = true
        if (state.hash !== undefined) forget(state.hash)
        connection?.close()
        update({ room: undefined, notice: 'This meeting was called off.' })
        return
      }
      update({
        notice: message.reason === 'expired' ? 'This meeting has ended.' : 'This meeting failed.',
      })
      void resume()
      return
  }
}

function onError(reason: string): void {
  const { alias, free } = memory()
  const reaction = errored(session, reason, { alias, answered: free !== undefined })
  session = reaction.session
  if (reaction.rejoinAs !== undefined) {
    connection?.send({ type: 'join', alias: reaction.rejoinAs })
    return
  }
  update({ joined: session.joined, notice: readable(reason) })
}

function storedMask(grid: Grid): Uint8Array {
  const stored = memory().free
  const decoded = stored === undefined ? undefined : decodeMask(stored, grid)
  return decoded ?? emptyMask(grid)
}

function readable(reason: string): string {
  const messages: Record<string, string> = {
    full: 'This meeting is full.',
    still_waiting: 'Everyone has to say when they are free before a time can be chosen.',
    expired: 'This meeting has ended.',
    forbidden: 'Only the person who started this meeting can choose a time.',
    duplicate: 'You have already joined.',
    bad_alias: 'That name will not work — up to 32 ordinary characters, please.',
    bad_slot: 'That availability did not match this meeting. Reload and try again.',
    too_fragmented: 'That is too many separate blocks — try marking longer stretches.',
    unknown_attendee: 'You are no longer in this meeting. Reload to rejoin.',
  }
  return messages[reason] ?? reason
}

// ---------- start ----------

if (hash !== undefined) {
  connection = connect(hash, {
    status: (status) => {
      update({ status })
      if (status === 'open') session = connected(session)
      if (status === 'closed') void resume()
    },
    message: onMessage,
  })
  window.addEventListener('beforeunload', () => connection?.close())
}

render(app(state, actions), root)
