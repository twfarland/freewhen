// Real layouts, not synthetic ones: the interesting edges come from how the
// week actually falls into local days, which is what columns() decides.
process.env.TZ = 'Europe/London'

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { destination, locate } from './navigate.ts'
import type { Day } from './navigate.ts'
import { columns } from './time.ts'

// Three ordinary days of 96 quarter-hours.
const days: Day[] = [0, 1, 2].map((day) => ({
  slots: Array.from({ length: 96 }, (_unused, index) => day * 96 + index),
}))

test('a slot knows which day it is in and where', () => {
  assert.deepEqual(locate(days, 0), { day: 0, index: 0 })
  assert.deepEqual(locate(days, 95), { day: 0, index: 95 })
  assert.deepEqual(locate(days, 96), { day: 1, index: 0 })
  assert.equal(locate(days, 9999), undefined)
})

test('up and down move an hour at a time within the day', () => {
  assert.equal(destination(days, 10, 'ArrowDown'), 11)
  assert.equal(destination(days, 10, 'ArrowUp'), 9)
})

test('a day does not run into the next one', () => {
  assert.equal(destination(days, 0, 'ArrowUp'), undefined)
  assert.equal(destination(days, 95, 'ArrowDown'), undefined)
})

test('left and right keep the time of day and change the day', () => {
  assert.equal(destination(days, 10, 'ArrowRight'), 106)
  assert.equal(destination(days, 106, 'ArrowLeft'), 10)
})

test('the week does not wrap at either end', () => {
  assert.equal(destination(days, 10, 'ArrowLeft'), undefined)
  assert.equal(destination(days, 202, 'ArrowRight'), undefined)
})

test('home and end are the ends of the day you are in', () => {
  assert.equal(destination(days, 50, 'Home'), 96 * 0)
  assert.equal(destination(days, 50, 'End'), 95)
  assert.equal(destination(days, 150, 'Home'), 96)
  assert.equal(destination(days, 150, 'End'), 191)
})

test('keys we do not handle are left to the browser', () => {
  for (const key of ['Tab', 'a', 'Escape', 'PageDown']) {
    assert.equal(destination(days, 10, key), undefined, key)
  }
})

test('an unknown slot goes nowhere rather than throwing', () => {
  assert.equal(destination(days, -1, 'ArrowDown'), undefined)
})

// Moving sideways off the end of a shorter day has to land somewhere real.
test('the short day the clocks go forward is not walked off the end of', () => {
  // Sunday 29 March 2026 has 23 hours; the Saturday before it has 24.
  const week = columns({ startsAt: Date.UTC(2026, 2, 28, 0, 0), slotMinutes: 15, slots: 96 * 3 })
  const saturday = week[0]
  const sunday = week[1]
  assert.equal(saturday?.slots.length, 96)
  assert.equal(sunday?.slots.length, 92)

  const lastOfSaturday = saturday?.slots.at(-1) ?? -1
  const landing = destination(week, lastOfSaturday, 'ArrowRight')
  assert.equal(landing, sunday?.slots.at(-1))
})

test('the long day the clocks go back is reachable all the way down', () => {
  // Sunday 25 October 2026 has 25 hours.
  const week = columns({ startsAt: Date.UTC(2026, 9, 24, 23, 0), slotMinutes: 15, slots: 96 * 3 })
  const sunday = week[0]
  assert.equal(sunday?.slots.length, 100)
  assert.equal(destination(week, sunday?.slots[98] ?? -1, 'ArrowDown'), sunday?.slots[99])
  assert.equal(destination(week, sunday?.slots.at(-1) ?? -1, 'ArrowDown'), undefined)
})
