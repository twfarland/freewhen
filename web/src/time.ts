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

import type { Hours } from './hours.ts'
import type { Grid } from './protocol.ts'

export type Column = { label: string; slots: number[] }

const HOURS_PER_MARK = 3

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

/** A proposal in a narrow column: the day, then the time it starts. */
export function brief(at: number): string {
  return `${format(at, { weekday: 'short', day: 'numeric', month: 'short' })}, ${clock(at)}`
}

// A grid arrives freshly parsed on every message, so these are keyed by value
// rather than identity. Formatting 672 slots costs a few milliseconds of Intl
// and the answer never changes for a given grid.
const columnCache = new Map<string, Column[]>()
const labelCache = new Map<string, string[]>()
const hourCache = new Map<string, (string | undefined)[]>()
const withinCache = new Map<string, boolean[]>()

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

/** The compact hour, for the grid's gutter: "9 AM" rather than "09:00 AM". */
export function hourOf(at: number): string {
  return format(at, { hour: 'numeric' })
}

/**
 * The clock label for each slot that opens a three-hour block, and `undefined`
 * for the rest. Read from each slot's own local time, so the hour a clock
 * change repeats or skips lands where it actually falls rather than where
 * counting from the start would put it.
 *
 * Every hour was too much to read: eight labels a day are enough to know where
 * you are, and the grid is meant to be scanned rather than studied.
 */
export function hourMarks(grid: Grid): (string | undefined)[] {
  return cached(hourCache, grid, () =>
    Array.from({ length: grid.slots }, (_unused, slot) => {
      const at = new Date(slotAt(grid, slot))
      const opens = at.getMinutes() === 0 && at.getHours() % HOURS_PER_MARK === 0
      return opens ? hourOf(at.getTime()) : undefined
    }),
  )
}

/**
 * Which slots fall inside this viewer's working day, so the rest can recede.
 * Time of day only — a Saturday morning is a perfectly ordinary time to meet
 * and dimming the weekend would be someone else's opinion.
 */
export function withinHours(grid: Grid, hours: Hours): boolean[] {
  const key = `${hours.start}-${hours.end}`
  return cached(withinCache, grid, () =>
    Array.from({ length: grid.slots }, (_unused, slot) => {
      const at = new Date(slotAt(grid, slot))
      const minutes = at.getHours() * 60 + at.getMinutes()
      return minutes >= hours.start && minutes < hours.end
    }),
  key)
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

function cached<T>(store: Map<string, T>, grid: Grid, build: () => T, extra = ''): T {
  const key = `${grid.startsAt}:${grid.slotMinutes}:${grid.slots}:${extra}`
  const found = store.get(key)
  if (found !== undefined) return found
  const built = build()
  store.set(key, built)
  return built
}

function format(at: number, style: Intl.DateTimeFormatOptions): string {
  return new Date(at).toLocaleString([], style)
}
