import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DEFAULT_HOURS, areHours, asClock, fromClock } from './hours.ts'

test('the default working day is nine to five', () => {
  assert.deepEqual(DEFAULT_HOURS, { start: 540, end: 1020 })
})

test('minutes render as the HH:MM an input wants', () => {
  assert.equal(asClock(0), '00:00')
  assert.equal(asClock(540), '09:00')
  assert.equal(asClock(1020), '17:00')
  assert.equal(asClock(1439), '23:59')
})

test('HH:MM reads back as minutes', () => {
  assert.equal(fromClock('00:00'), 0)
  assert.equal(fromClock('09:30'), 570)
  assert.equal(fromClock('23:59'), 1439)
})

test('what an input cannot produce is refused rather than guessed', () => {
  for (const bad of ['', '9:00', '09:00:00', 'nine', '25:00', '99:99']) {
    assert.equal(fromClock(bad), undefined, bad)
  }
})

test('every minute of the day survives the round trip', () => {
  for (let minutes = 0; minutes < 1440; minutes++) {
    assert.equal(fromClock(asClock(minutes)), minutes)
  }
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
