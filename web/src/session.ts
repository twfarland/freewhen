// Whether this browser holds a place in the room, and what to do when the
// server says it does not.
//
// `joined` means "this browser holds an id the room accepted", not "this tab
// sent a join" — it has to survive a reload, because joining twice mints a
// second attendee and inflates the counts. Kept pure and out of main.ts so
// every reconnection path is testable without a socket or a DOM.

export type Session = {
  /** This browser holds an attendee id the room has accepted. */
  joined: boolean
  /** A rejoin is in flight, so the next error is about that and not the last thing the user did. */
  rejoining: boolean
  /** This connection has not yet handed back what this browser was holding. */
  unrestored: boolean
}

/** What this browser is holding on the room's behalf. */
export type Holding = {
  /** The alias it joined under, if it ever joined. */
  alias: string | undefined
  /** Whether it has an answer worth handing back. */
  answered: boolean
}

/** What main.ts should do about an error, beyond showing it. */
export type Reaction = {
  session: Session
  /** Send a join under this alias, and say nothing to the user. */
  rejoinAs?: string
}

/** This browser is in the room if it kept an id from last time. */
export function opened(attendeeId: string | undefined): Session {
  return { joined: attendeeId !== undefined, rejoining: false, unrestored: false }
}

/** The server issued an id, so whatever we thought before, we are in. */
export function accepted(session: Session): Session {
  return { ...session, joined: true, rejoining: false }
}

/** A socket opened: what this browser holds is owed to the room once. */
export function connected(session: Session): Session {
  return { ...session, unrestored: true }
}

/**
 * Whether this `state` is the one to resubmit against.
 *
 * Only the first per connection. The server publishes a `state` after every
 * successful command, so a client that resubmitted on each one would answer
 * its own submit forever — which is exactly what it used to do, and every
 * paint set off an endless loop.
 */
export function restoring(session: Session): { session: Session; resubmit: boolean } {
  if (!session.unrestored) return { session, resubmit: false }
  return { session: { ...session, unrestored: false }, resubmit: true }
}

export function errored(session: Session, reason: string, holding: Holding): Reaction {
  // The room was rebuilt without us: take our place again rather than show an
  // error nobody can act on. Once only, or a room that keeps refusing is asked
  // forever — and only with an answer to hand back, because a tab that joined
  // and never said anything has nothing to restore, and rejoining it would
  // undo a host who deliberately went ahead without them.
  const { alias, answered } = holding
  if (reason === 'unknown_attendee' && alias !== undefined && answered && !session.rejoining) {
    return { session: { ...session, rejoining: true }, rejoinAs: alias }
  }
  // The rejoin failed, so this browser holds an id the room does not know.
  if (session.rejoining) {
    return { session: { ...session, joined: false, rejoining: false } }
  }
  // Anything else — a rejected availability, a full room — says nothing about
  // whether we have a place in it.
  return { session }
}
