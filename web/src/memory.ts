// What this browser remembers about a room, so that a release does not cost
// anyone their answer.
//
// The server keeps nothing across a restart by design. What makes a room
// survive one is that the people in it are each holding the piece that
// concerns them: the host holds the token the room's address derives from, and
// everyone holds their own availability. Recovery is those pieces being handed
// back in.
//
// It lives in localStorage, which never leaves this machine.

import type { Hours } from './hours.ts'
import type { RoomShape } from './protocol.ts'

export type Memory = {
  /** Only the host has this. It is both the right to pick and the right to resume. */
  hostToken?: string
  alias?: string
  attendeeId?: string
  /** Base64url packed free-time bits, exactly as sent. */
  free?: string
  /** Enough to rebuild the same room after the server has forgotten it. */
  shape?: RoomShape
  /** This person's working day, if it is not nine to five. */
  hours?: Hours
}

const PREFIX = 'freewhen:'

export function recall(hash: string): Memory {
  try {
    const stored = localStorage.getItem(PREFIX + hash)
    return stored === null ? {} : (JSON.parse(stored) as Memory)
  } catch {
    return {}
  }
}

export function remember(hash: string, patch: Memory): Memory {
  const next = { ...recall(hash), ...patch }
  try {
    localStorage.setItem(PREFIX + hash, JSON.stringify(next))
  } catch {
    // A browser refusing to store is not a reason to stop working.
  }
  return next
}

export function forget(hash: string): void {
  try {
    localStorage.removeItem(PREFIX + hash)
  } catch {
    // Nothing to do; it will fall out of the browser eventually.
  }
}
