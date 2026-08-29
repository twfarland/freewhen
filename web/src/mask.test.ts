// Nothing here reads a clock at import time, which is what makes setting TZ
// after the (hoisted) imports work: the zone is read on the first Date, and
// that happens inside a test. Europe/London rather than UTC because the point
// of half of these is what a clock change does.
process.env.TZ = 'Europe/London'

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { decodeMask, emptyMask, encodeMask, isFree, preset, setSlot } from './mask.ts'
import { DEFAULT_HOURS } from './hours.ts'
import type { Grid } from './protocol.ts'

function grid(startsAt: number, slots: number, slotMinutes = 15): Grid {
  return { startsAt, slotMinutes, slots }
}

const week = grid(Date.UTC(2026, 5, 1, 0, 0), 672)

test('an empty mask is one bit per slot, rounded up to a byte', () => {
  assert.equal(emptyMask(grid(0, 672)).length, 84)
  assert.equal(emptyMask(grid(0, 1)).length, 1)
  assert.equal(emptyMask(grid(0, 8)).length, 1)
  assert.equal(emptyMask(grid(0, 9)).length, 2)
})

test('bits are most significant first, matching the Erlang side', () => {
  const mask = emptyMask(grid(0, 16))
  setSlot(mask, 0, true)
  assert.equal(mask[0], 0b1000_0000)
  setSlot(mask, 7, true)
  assert.equal(mask[0], 0b1000_0001)
  setSlot(mask, 8, true)
  assert.equal(mask[1], 0b1000_0000)
})

test('a slot reads back the way it was set, and clears', () => {
  const mask = emptyMask(grid(0, 32))
  assert.equal(isFree(mask, 5), false)
  setSlot(mask, 5, true)
  assert.equal(isFree(mask, 5), true)
  assert.equal(isFree(mask, 4), false)
  assert.equal(isFree(mask, 6), false)
  setSlot(mask, 5, false)
  assert.equal(isFree(mask, 5), false)
})

test('encoding is base64url, with nothing a URL would object to', () => {
  const mask = Uint8Array.from([0xfb, 0xff, 0xbf, 0xff])
  const encoded = encodeMask(mask)
  assert.doesNotMatch(encoded, /[+/=]/)
})

test('a mask survives the round trip through storage', () => {
  const mask = preset(week, 'weekdays')
  const back = decodeMask(encodeMask(mask), week)
  assert.deepEqual(back, mask)
})

test('a mask from a differently shaped room is discarded, not misread', () => {
  const encoded = encodeMask(preset(week, 'always'))
  assert.equal(decodeMask(encoded, grid(week.startsAt, 96)), undefined)
})

test('garbage is discarded rather than thrown', () => {
  assert.equal(decodeMask('not base64 at all!!', week), undefined)
})

test('never is free nowhere and always is free everywhere', () => {
  const never = preset(week, 'never')
  const always = preset(week, 'always')
  for (let slot = 0; slot < week.slots; slot++) {
    assert.equal(isFree(never, slot), false, `never at ${slot}`)
    assert.equal(isFree(always, slot), true, `always at ${slot}`)
  }
})

test('weekdays is nine to five, local, and not the weekend', () => {
  // Monday 1 June 2026, 00:00 UTC — British Summer Time, so 01:00 local.
  const mask = preset(week, 'weekdays')
  const slotOf = (day: number, hour: number, minute = 0) =>
    (day * 24 * 60 + hour * 60 + minute) / 15

  // Monday, in local hours: 09:00 is 08:00 UTC.
  assert.equal(isFree(mask, slotOf(0, 8, 0)), true, 'Monday 09:00 local')
  assert.equal(isFree(mask, slotOf(0, 7, 45)), false, 'Monday 08:45 local')
  assert.equal(isFree(mask, slotOf(0, 15, 45)), true, 'Monday 16:45 local')
  assert.equal(isFree(mask, slotOf(0, 16, 0)), false, 'Monday 17:00 local')
  // Saturday is the sixth day of this grid.
  assert.equal(isFree(mask, slotOf(5, 12, 0)), false, 'Saturday midday')
})

// The preset reads each slot's own local time rather than counting from the
// start, so a week containing a clock change is right on both sides of it.
test('weekdays is right on both sides of a clock change', () => {
  // Sunday 25 October 2026: British Summer Time ends, clocks go back an hour.
  const across = grid(Date.UTC(2026, 9, 22, 0, 0), 672)
  const mask = preset(across, 'weekdays')
  const at = (utc: number) => Math.round((utc - across.startsAt) / (15 * 60_000))

  // Thursday, before the change: 09:00 local is 08:00 UTC.
  assert.equal(isFree(mask, at(Date.UTC(2026, 9, 22, 8, 0))), true, 'Thu 09:00 BST')
  assert.equal(isFree(mask, at(Date.UTC(2026, 9, 22, 7, 45))), false, 'Thu 08:45 BST')
  // Monday, after it: 09:00 local is 09:00 UTC.
  assert.equal(isFree(mask, at(Date.UTC(2026, 9, 26, 9, 0))), true, 'Mon 09:00 GMT')
  assert.equal(isFree(mask, at(Date.UTC(2026, 9, 26, 8, 45))), false, 'Mon 08:45 GMT')
  // A naive offset would have put Monday's window an hour early.
  assert.equal(isFree(mask, at(Date.UTC(2026, 9, 26, 16, 45))), true, 'Mon 16:45 GMT')
  assert.equal(isFree(mask, at(Date.UTC(2026, 9, 26, 17, 0))), false, 'Mon 17:00 GMT')
})

// Nine to five is most people's week and nobody else's, so the boundaries move.
test('the working day is whatever somebody says it is', () => {
  const early = preset(week, 'weekdays', { start: 7 * 60, end: 15 * 60 })
  const slotOf = (day: number, hour: number, minute = 0) =>
    (day * 24 * 60 + hour * 60 + minute) / 15

  // Monday, local hours: BST, so 07:00 local is 06:00 UTC.
  assert.equal(isFree(early, slotOf(0, 6, 0)), true, 'Monday 07:00 local')
  assert.equal(isFree(early, slotOf(0, 5, 45)), false, 'Monday 06:45 local')
  assert.equal(isFree(early, slotOf(0, 13, 45)), true, 'Monday 14:45 local')
  assert.equal(isFree(early, slotOf(0, 14, 0)), false, 'Monday 15:00 local')
  // Still nothing at the weekend.
  assert.equal(isFree(early, slotOf(5, 10, 0)), false, 'Saturday')
})

test('omitting the hours is the same as asking for nine to five', () => {
  assert.deepEqual(preset(week, 'weekdays'), preset(week, 'weekdays', DEFAULT_HOURS))
})

test('the hours make no difference to the other two presets', () => {
  const odd = { start: 3 * 60, end: 4 * 60 }
  assert.deepEqual(preset(week, 'always', odd), preset(week, 'always'))
  assert.deepEqual(preset(week, 'never', odd), preset(week, 'never'))
})
