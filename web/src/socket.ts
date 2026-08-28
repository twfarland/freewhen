// One socket per room, reconnecting with backoff.
//
// Reconnect needs no protocol support: the server's first message on any
// connection is the whole room, so recovery is just opening it again.
//
// It never gives up. A closed socket means the room is missing, and after a
// release that is temporary — the host's browser is about to reopen it at the
// same address. Guests have nothing to do but keep knocking, so the backoff
// caps at ten seconds and they rejoin on their own within that.

import type { ClientMessage, ServerMessage } from './protocol.ts'

export type Status = 'connecting' | 'open' | 'closed'

export type Handlers = {
  message: (message: ServerMessage) => void
  status: (status: Status) => void
}

export type Connection = {
  /** Dropped silently while disconnected: every command is safe to retry. */
  send: (message: ClientMessage) => void
  /** Try again immediately, for when we know the room has just come back. */
  retryNow: () => void
  close: () => void
}

const FIRST_RETRY_MS = 500
const MAX_RETRY_MS = 10_000

export function connect(hash: string, handlers: Handlers): Connection {
  let socket: WebSocket | undefined
  let retry = FIRST_RETRY_MS
  let timer: number | undefined
  let stopped = false

  const url = (): string => {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
    return `${scheme}://${location.host}/ws/rooms/${encodeURIComponent(hash)}`
  }

  const open = (): void => {
    if (stopped) return
    handlers.status('connecting')
    const next = new WebSocket(url())
    socket = next

    next.onopen = () => {
      retry = FIRST_RETRY_MS
      handlers.status('open')
    }

    next.onmessage = (event: MessageEvent<string>) => {
      handlers.message(JSON.parse(event.data) as ServerMessage)
    }

    next.onclose = () => {
      socket = undefined
      handlers.status('closed')
      schedule(retry)
      retry = Math.min(retry * 2, MAX_RETRY_MS)
    }
  }

  const schedule = (delay: number): void => {
    if (stopped) return
    if (timer !== undefined) window.clearTimeout(timer)
    timer = window.setTimeout(open, delay)
  }

  open()

  return {
    send: (message) => {
      if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message))
    },
    retryNow: () => {
      retry = FIRST_RETRY_MS
      if (socket === undefined) schedule(0)
    },
    close: () => {
      stopped = true
      if (timer !== undefined) window.clearTimeout(timer)
      socket?.close()
    },
  }
}
