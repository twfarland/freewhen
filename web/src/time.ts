// Formatting, and nothing else.
//
// Every instant here arrived from the server as UTC milliseconds, already
// decided. Turning those into local words is the one job left to the browser,
// and it is the reason the server never needs to know where anybody is: it has
// a timezone database, the BEAM does not, and the conversion belongs on the
// side that also knows the locale.
//
// The only arithmetic is laying the grid out into columns, because how many
// cells fit in a local day is a question about the viewer's calendar rather
// than about the meeting.

import type { Grid } from './protocol.ts'

export type Column = { label: string; slots: number[] }

export function slotAt(grid: Grid, slot: number): number {
  return grid.startsAt + slot * grid.slotMinutes * 60_000
}

/** The full sentence for a range, in the viewer's own zone. */
export function span(startsAt: number, endsAt: number): string {
  const day = format(startsAt, { weekday: 'long', day: 'numeric', month: 'long' })
  return `${day}, ${clock(startsAt)} – ${clock(endsAt)}`
}

export function clock(at: number): string {
  return format(at, { hour: '2-digit', minute: '2-digit' })
}

// A grid arrives freshly parsed on every message, so these are keyed by value
// rather than identity. Formatting 672 slots costs a few milliseconds of Intl
// and the answer never changes for a given grid.
const columnCache = new Map<string, Column[]>()
const labelCache = new Map<string, string[]>()

export function columns(grid: Grid): Column[] {
  return cached(columnCache, grid, () => {
    const days = new Map<string, number[]>()
    for (let slot = 0; slot < grid.slots; slot++) {
      const key = format(slotAt(grid, slot), {
        weekday: 'short',
        day: 'numeric',
        month: 'short',
      })
      const existing = days.get(key)
      if (existing === undefined) days.set(key, [slot])
      else existing.push(slot)
    }
    return [...days.entries()].map(([label, slots]) => ({ label, slots }))
  })
}

/** One label per slot, for the grid's cells. */
export function slotLabels(grid: Grid): string[] {
  return cached(labelCache, grid, () =>
    Array.from({ length: grid.slots }, (_unused, slot) => {
      const at = slotAt(grid, slot)
      return span(at, at + grid.slotMinutes * 60_000)
    }),
  )
}

// ---------- internal ----------

function cached<T>(store: Map<string, T>, grid: Grid, build: () => T): T {
  const key = `${grid.startsAt}:${grid.slotMinutes}:${grid.slots}`
  const found = store.get(key)
  if (found !== undefined) return found
  const built = build()
  store.set(key, built)
  return built
}

function format(at: number, style: Intl.DateTimeFormatOptions): string {
  return new Date(at).toLocaleString([], style)
}
