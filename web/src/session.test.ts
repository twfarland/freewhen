import { test } from 'node:test'
import assert from 'node:assert/strict'
import { accepted, errored, opened } from './session.ts'
import type { Session } from './session.ts'

const fresh: Session = { joined: false, rejoining: false }
const inRoom: Session = { joined: true, rejoining: false }
const midRejoin: Session = { joined: true, rejoining: true }

test('a browser with no remembered id is not in the room', () => {
  assert.deepEqual(opened(undefined), { joined: false, rejoining: false })
})

test('a browser that remembers an id is still in the room after a reload', () => {
  assert.deepEqual(opened('att-1'), { joined: true, rejoining: false })
})

test('being issued an id puts you in the room whatever you thought before', () => {
  assert.deepEqual(accepted(), { joined: true, rejoining: false })
})

test('a room that has forgotten us is rejoined under the remembered alias', () => {
  const reaction = errored(inRoom, 'unknown_attendee', 'Blue Falcon')
  assert.equal(reaction.rejoinAs, 'Blue Falcon')
  assert.deepEqual(reaction.session, { joined: true, rejoining: true })
})

test('a room that has forgotten us with no alias to offer just reports', () => {
  const reaction = errored(inRoom, 'unknown_attendee', undefined)
  assert.equal(reaction.rejoinAs, undefined)
  assert.deepEqual(reaction.session, inRoom)
})

test('a rejoin is attempted once, not forever', () => {
  const reaction = errored(midRejoin, 'unknown_attendee', 'Blue Falcon')
  assert.equal(reaction.rejoinAs, undefined)
})

test('a rejoin that fails leaves the join form as the only thing to offer', () => {
  const reaction = errored(midRejoin, 'full', 'Blue Falcon')
  assert.equal(reaction.rejoinAs, undefined)
  assert.deepEqual(reaction.session, { joined: false, rejoining: false })
})

// The bug this file exists for had the opposite shape, but the mirror image is
// just as bad: a rejected availability must not throw someone out of the room.
test('an error about what we sent says nothing about our place in the room', () => {
  for (const reason of ['too_fragmented', 'bad_slot', 'forbidden', 'finalized']) {
    assert.deepEqual(errored(inRoom, reason, 'Blue Falcon').session, inRoom, reason)
  }
})

test('an error before joining leaves us out of the room', () => {
  assert.deepEqual(errored(fresh, 'bad_alias', undefined).session, fresh)
})
