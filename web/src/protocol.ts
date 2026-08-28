// The wire, as types. The server's half lives in fw_room_json.erl and the two
// must change together.
//
// Note what the server sends: proposals carry UTC instants, not slot numbers.
// The browser formats and does no arithmetic — every fact here was computed on
// the server, and every instant is UTC. Nothing tells the server where anybody
// is; converting to local time is this side's job and stays here.

export type Grid = {
  startsAt: number
  slotMinutes: number
  slots: number
}

export type Attendee = {
  alias: string
  /** Whether this person has said when they are busy. */
  ready: boolean
}

export type Proposal = {
  slot: number
  free: number
  startsAt: number
  endsAt: number
}

export type Room = {
  grid: Grid
  durationSlots: number
  attendees: Attendee[]
  /** How many attendees are free, per slot. Never who. */
  heatmap: number[]
  proposals: Proposal[]
  chosen: Proposal | null
  expiresAt: number
}

export type ServerMessage =
  | { type: 'state'; room: Room }
  | { type: 'joined'; attendeeId: string }
  | { type: 'error'; reason: string }
  | { type: 'closed'; reason: string }

export type ClientMessage =
  | { type: 'join'; alias: string }
  | { type: 'submit'; attendeeId: string; busy: string }
  | { type: 'leave'; attendeeId: string }
  | { type: 'pick'; hostToken: string; slot: number }

export type RoomShape = {
  startsAt: number
  slotMinutes: number
  slots: number
  durationSlots: number
}

export type Created = {
  hash: string
  hostToken: string
}

/**
 * Open a room.
 *
 * With `resume`, the server reopens the room that token derives instead of
 * minting a new one — which is how a room comes back after a release. It is
 * idempotent, so a client that is unsure whether the room is gone can simply
 * ask.
 */
export async function openRoom(shape: RoomShape, resume?: string): Promise<Created> {
  const response = await fetch('/api/rooms', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(resume === undefined ? shape : { ...shape, resume }),
  })
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string }
    throw new Error(body.error ?? `could not open the room (${response.status})`)
  }
  return (await response.json()) as Created
}
