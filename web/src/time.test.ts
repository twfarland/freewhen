// See mask.test.ts for why setting TZ here works. Europe/London because the
// interesting cases are the two days a year that are not 24 hours long.
process.env.TZ = 'Europe/London'

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { clock, columns, slotAt, slotLabels, span } from './time.ts'
import type { Grid } from './protocol.ts'

function grid(startsAt: number, slots: number, slotMinutes = 15): Grid {
  return { startsAt, slotMinutes, slots }
}

test('a slot is its offset from the start, in UTC, with no zone in sight', () => {
  const g = grid(Date.UTC(2026, 5, 1, 0, 0), 96)
  assert.equal(slotAt(g, 0), Date.UTC(2026, 5, 1, 0, 0))
  assert.equal(slotAt(g, 1), Date.UTC(2026, 5, 1, 0, 15))
  assert.equal(slotAt(g, 95), Date.UTC(2026, 5, 1, 23, 45))
})

// Locale varies between a laptop and CI, so these assert the parts that are
// the same everywhere rather than a rendered string.
test('a clock reads as the local hour and minute', () => {
  assert.match(clock(Date.UTC(2026, 5, 1, 8, 30)), /09[:.]30/)
})

test('a span carries both ends and the day', () => {
  const text = span(Date.UTC(2026, 5, 1, 8, 0), Date.UTC(2026, 5, 1, 9, 0))
  assert.match(text, /09[:.]00/)
  assert.match(text, /10[:.]00/)
  assert.match(text, /Monday/)
})

test('a grid lays out into local days', () => {
  // Local midnight on 1 June 2026 is 23:00 UTC on 31 May: British Summer Time.
  const g = grid(Date.UTC(2026, 4, 31, 23, 0), 96 * 3)
  const laid = columns(g)
  assert.equal(laid.length, 3)
  assert.deepEqual(laid.map((column) => column.slots.length), [96, 96, 96])
  assert.equal(laid[0]?.slots[0], 0)
  assert.equal(laid[1]?.slots[0], 96)
})

// The reason the client is allowed to do this arithmetic and the server is not.
test('the day the clocks go back has twenty-five hours in it', () => {
  // Local midnight, Sunday 25 October 2026. BST ends at 02:00 that morning.
  const g = grid(Date.UTC(2026, 9, 24, 23, 0), 96 * 3)
  const laid = columns(g)
  assert.equal(laid[0]?.slots.length, 100)
})

test('the day the clocks go forward has twenty-three', () => {
  // Local midnight, Sunday 29 March 2026. BST begins at 01:00 GMT.
  const g = grid(Date.UTC(2026, 2, 29, 0, 0), 96 * 3)
  const laid = columns(g)
  assert.equal(laid[0]?.slots.length, 92)
})

test('every slot gets exactly one label', () => {
  const g = grid(Date.UTC(2026, 5, 1, 0, 0), 96)
  const labels = slotLabels(g)
  assert.equal(labels.length, 96)
  assert.match(labels[0] ?? '', /01[:.]00/)
})

// A grid arrives freshly parsed on every message, so the cache has to be keyed
// by value. If it were keyed by identity it would never hit and the Intl cost
// would be paid on every render.
test('two grids with the same shape share one layout', () => {
  const shape = () => grid(Date.UTC(2026, 5, 8, 0, 0), 96)
  assert.equal(columns(shape()), columns(shape()))
  assert.equal(slotLabels(shape()), slotLabels(shape()))
})

test('a grid of a different shape gets its own layout', () => {
  const one = columns(grid(Date.UTC(2026, 5, 15, 0, 0), 96))
  const other = columns(grid(Date.UTC(2026, 5, 15, 0, 0), 192))
  assert.notEqual(one, other)
})
