// State, actions, and one render call. Everything visual is in view.ts.
//
// The room hash lives in the URL fragment, which browsers do not send to the
// server when loading a page. The host token lives in localStorage and is
// never in a URL at all.
//
// ## Coming back after a release
//
// The server keeps nothing across a restart, so recovery is the people in the
// room handing back the pieces they were holding. On every connection this
// client resubmits what it remembers; if the server says it has never heard of
// this attendee, the room was rebuilt and it rejoins first. A host whose room
// has gone entirely reopens it at the same address by presenting its token —
// see docs/adr/0008.

import { render } from 'lit'
import { download, invite } from './invite.ts'
import { decodeMask, emptyMask, encodeMask, preset as presetMask, setSlot } from './mask.ts'
import { recall, remember } from './memory.ts'
import type { Memory } from './memory.ts'
import { openRoom } from './protocol.ts'
import type { Grid, RoomShape, ServerMessage } from './protocol.ts'
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

let state: State = {
  hash,
  isHost: hash !== undefined && recall(hash).hostToken !== undefined,
  status: 'connecting',
  notice: '',
  busy: false,
  room: undefined,
  mine: undefined,
  joined: false,
}

let connection: Connection | undefined
let pending: number | undefined
let resuming = false

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

  join: (alias) => {
    if (state.hash !== undefined) remember(state.hash, { alias })
    connection?.send({ type: 'join', alias })
  },

  preset: (kind) => {
    if (state.room === undefined) return
    update({ mine: presetMask(state.room.grid, kind) })
    submit()
  },

  paint: (slot, busy) => {
    if (state.mine === undefined) return
    const mine = Uint8Array.from(state.mine)
    setSlot(mine, slot, busy)
    update({ mine })
    submit()
  },

  pick: (slot) => {
    const hostToken = memory().hostToken
    if (hostToken !== undefined) connection?.send({ type: 'pick', hostToken, slot })
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
  const slotMinutes = Number(data.get('slotMinutes'))
  const days = Number(data.get('days'))
  const minutes = Number(data.get('duration'))
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
    const notice = error instanceof Error ? error.message : 'could not create the room'
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
  const busy = encodeMask(state.mine)
  remember(state.hash, { busy })
  connection?.send({ type: 'submit', attendeeId, busy })
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
  if (resuming || hostToken === undefined || shape === undefined) return
  resuming = true
  update({ notice: 'the server restarted — reopening this room…' })
  try {
    await openRoom(shape, hostToken)
    connection?.retryNow()
  } catch {
    update({ notice: 'could not reopen this room.' })
  } finally {
    resuming = false
  }
}

/** Hand back whatever this browser was holding. */
function restore(): void {
  const { attendeeId, busy } = memory()
  if (attendeeId === undefined || busy === undefined) return
  connection?.send({ type: 'submit', attendeeId, busy })
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
      restore()
      return
    case 'joined':
      if (state.hash !== undefined) remember(state.hash, { attendeeId: message.attendeeId })
      update({ joined: true })
      sendAvailability()
      return
    case 'error':
      onError(message.reason)
      return
    case 'closed':
      update({ notice: message.reason === 'expired' ? 'This room has ended.' : 'This room failed.' })
      void resume()
      return
  }
}

// The room was rebuilt without us, so take our place in it again rather than
// showing an error nobody can act on.
function onError(reason: string): void {
  const { alias } = memory()
  if (reason === 'unknown_attendee' && alias !== undefined) {
    connection?.send({ type: 'join', alias })
    return
  }
  update({ notice: readable(reason) })
}

function storedMask(grid: Grid): Uint8Array {
  const stored = memory().busy
  const decoded = stored === undefined ? undefined : decodeMask(stored, grid)
  return decoded ?? emptyMask(grid)
}

function readable(reason: string): string {
  const messages: Record<string, string> = {
    full: 'This room is full.',
    finalized: 'A time has already been chosen.',
    expired: 'This room has ended.',
    forbidden: 'Only the person who started this room can choose a time.',
    duplicate: 'You have already joined.',
    bad_alias: 'That name will not work — up to 32 ordinary characters, please.',
    bad_slot: 'That availability did not match this room. Reload and try again.',
    unknown_attendee: 'You are not in this room any more. Reload to rejoin.',
  }
  return messages[reason] ?? reason
}

// ---------- start ----------

if (hash !== undefined) {
  connection = connect(hash, {
    status: (status) => {
      update({ status })
      if (status === 'closed') void resume()
    },
    message: onMessage,
  })
  window.addEventListener('beforeunload', () => connection?.close())
}

render(app(state, actions), root)
