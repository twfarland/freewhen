import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DEFAULT_HOURS, areHours, asClock } from './hours.ts'

test('the default working day is nine to five', () => {
  assert.deepEqual(DEFAULT_HOURS, { start: 540, end: 1020 })
})

test('minutes render as the HH:MM an input wants', () => {
  assert.equal(asClock(0), '00:00')
  assert.equal(asClock(540), '09:00')
  assert.equal(asClock(1020), '17:00')
  assert.equal(asClock(1439), '23:59')
})

// A day that ends before it starts selects nothing, which is never what
// somebody dragging a time input meant.
test('a day has to end after it starts', () => {
  assert.equal(areHours({ start: 540, end: 1020 }), true)
  assert.equal(areHours({ start: 1020, end: 540 }), false)
  assert.equal(areHours({ start: 540, end: 540 }), false)
})

test('anything that is not a pair of minutes is not working hours', () => {
  for (const bad of [undefined, null, 'nine to five', 540, {}, { start: 0 }, { start: '0', end: '1' }]) {
    assert.equal(areHours(bad), false, JSON.stringify(bad) ?? 'undefined')
  }
  assert.equal(areHours({ start: -1, end: 60 }), false)
  assert.equal(areHours({ start: 0, end: 1441 }), false)
  assert.equal(areHours({ start: 9.5, end: 60 }), false)
})
