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
}

/** What main.ts should do about an error, beyond showing it. */
export type Reaction = {
  session: Session
  /** Send a join under this alias, and say nothing to the user. */
  rejoinAs?: string
}

/** This browser is in the room if it kept an id from last time. */
export function opened(attendeeId: string | undefined): Session {
  return { joined: attendeeId !== undefined, rejoining: false }
}

/** The server issued an id, so whatever we thought before, we are in. */
export function accepted(): Session {
  return { joined: true, rejoining: false }
}

export function errored(session: Session, reason: string, alias: string | undefined): Reaction {
  // The room was rebuilt without us: take our place again rather than show an
  // error nobody can act on. Once only, or a room that keeps refusing is asked
  // forever.
  if (reason === 'unknown_attendee' && alias !== undefined && !session.rejoining) {
    return { session: { joined: session.joined, rejoining: true }, rejoinAs: alias }
  }
  // The rejoin failed, so this browser holds an id the room does not know.
  if (session.rejoining) {
    return { session: { joined: false, rejoining: false } }
  }
  // Anything else — a rejected availability, a full room — says nothing about
  // whether we have a place in it.
  return { session }
}
