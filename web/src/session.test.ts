import { test } from 'node:test'
import assert from 'node:assert/strict'
import { accepted, connected, errored, opened, restoring } from './session.ts'
import type { Session } from './session.ts'

const fresh: Session = { joined: false, rejoining: false, unrestored: false }
const inRoom: Session = { joined: true, rejoining: false, unrestored: false }
const midRejoin: Session = { joined: true, rejoining: true, unrestored: false }

test('a browser with no remembered id is not in the room', () => {
  assert.equal(opened(undefined).joined, false)
})

test('a browser that remembers an id is still in the room after a reload', () => {
  assert.equal(opened('att-1').joined, true)
})

test('being issued an id puts you in the room whatever you thought before', () => {
  assert.equal(accepted(fresh).joined, true)
})

// The server publishes a state after every successful command. A client that
// resubmitted on each one would answer its own submit forever, and every paint
// would set off an endless loop — which is what it used to do.
test('what this browser holds is handed back once per connection', () => {
  const open = connected(inRoom)
  const first = restoring(open)
  assert.equal(first.resubmit, true)

  const second = restoring(first.session)
  assert.equal(second.resubmit, false)

  const third = restoring(second.session)
  assert.equal(third.resubmit, false)
})

test('a fresh connection owes its answer again', () => {
  const { session } = restoring(connected(inRoom))
  assert.equal(restoring(connected(session)).resubmit, true)
})

test('a state before any connection opened owes nothing', () => {
  assert.equal(restoring(inRoom).resubmit, false)
})

test('reconnecting does not disturb whether we are in the room', () => {
  assert.equal(connected(inRoom).joined, true)
  assert.equal(connected(fresh).joined, false)
})

const holding = { alias: 'Blue Falcon', answered: true }
const empty = { alias: undefined, answered: false }

test('a room that has forgotten us is rejoined under the remembered alias', () => {
  const reaction = errored(inRoom, 'unknown_attendee', holding)
  assert.equal(reaction.rejoinAs, 'Blue Falcon')
  assert.equal(reaction.session.joined, true)
  assert.equal(reaction.session.rejoining, true)
})

test('a room that has forgotten us with no alias to offer just reports', () => {
  const reaction = errored(inRoom, 'unknown_attendee', empty)
  assert.equal(reaction.rejoinAs, undefined)
  assert.deepEqual(reaction.session, inRoom)
})

// A host who goes ahead without somebody who never answered must not have that
// person's open tab quietly put itself back in the room and shut the gate
// again. A browser with nothing to hand back has no claim to a place.
test('a tab that never answered does not rejoin a room that dropped it', () => {
  const reaction = errored(inRoom, 'unknown_attendee', { alias: 'Ghost', answered: false })
  assert.equal(reaction.rejoinAs, undefined)
  assert.deepEqual(reaction.session, inRoom)
})

test('a rejoin is attempted once, not forever', () => {
  const reaction = errored(midRejoin, 'unknown_attendee', holding)
  assert.equal(reaction.rejoinAs, undefined)
})

test('a rejoin that fails leaves the join form as the only thing to offer', () => {
  const reaction = errored(midRejoin, 'full', holding)
  assert.equal(reaction.rejoinAs, undefined)
  assert.equal(reaction.session.joined, false)
  assert.equal(reaction.session.rejoining, false)
})

// The bug this file exists for had the opposite shape, but the mirror image is
// just as bad: a rejected availability must not throw someone out of the room.
test('an error about what we sent says nothing about our place in the room', () => {
  for (const reason of ['too_fragmented', 'bad_slot', 'forbidden', 'still_waiting']) {
    assert.deepEqual(errored(inRoom, reason, holding).session, inRoom, reason)
  }
})

test('an error before joining leaves us out of the room', () => {
  assert.deepEqual(errored(fresh, 'bad_alias', empty).session, fresh)
})
