import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { forget, recall, remember } from './memory.ts'

// The smallest thing that satisfies the Storage interface. Node has no
// localStorage, and a stub is honest here: memory.ts uses three of its methods
// and the only interesting behaviour is what happens when they throw, which a
// real browser does in private mode and with storage disabled.
class Stub implements Storage {
  private items = new Map<string, string>()
  broken = false

  get length(): number {
    return this.items.size
  }
  clear(): void {
    this.items.clear()
  }
  getItem(key: string): string | null {
    if (this.broken) throw new Error('SecurityError')
    return this.items.get(key) ?? null
  }
  key(index: number): string | null {
    return [...this.items.keys()][index] ?? null
  }
  removeItem(key: string): void {
    if (this.broken) throw new Error('SecurityError')
    this.items.delete(key)
  }
  setItem(key: string, value: string): void {
    if (this.broken) throw new Error('QuotaExceededError')
    this.items.set(key, value)
  }
}

// memory.ts reads the global when it is called, not when it is imported, so a
// fresh stub per test is enough.
let stub: Stub

beforeEach(() => {
  stub = new Stub()
  globalThis.localStorage = stub
})

test('a room this browser has never seen remembers nothing', () => {
  assert.deepEqual(recall('unknown'), {})
})

test('what is remembered comes back', () => {
  remember('abc', { alias: 'Blue Falcon', attendeeId: 'att-1' })
  assert.deepEqual(recall('abc'), { alias: 'Blue Falcon', attendeeId: 'att-1' })
})

test('remembering merges rather than replaces', () => {
  remember('abc', { alias: 'Blue Falcon' })
  remember('abc', { free: 'AAAA' })
  assert.deepEqual(recall('abc'), { alias: 'Blue Falcon', free: 'AAAA' })
})

test('rooms do not see each other', () => {
  remember('one', { alias: 'A' })
  remember('two', { alias: 'B' })
  assert.equal(recall('one').alias, 'A')
  assert.equal(recall('two').alias, 'B')
})

test('forgetting a room forgets all of it', () => {
  remember('abc', { hostToken: 'secret', alias: 'Blue Falcon' })
  forget('abc')
  assert.deepEqual(recall('abc'), {})
})

test('a corrupted entry reads as nothing rather than throwing', () => {
  stub.setItem('freewhen:abc', 'not json')
  assert.deepEqual(recall('abc'), {})
})

// A browser refusing to store is not a reason to stop working: the room is
// still usable, it just will not survive a reload.
test('a browser that refuses to store does not break anything', () => {
  stub.broken = true
  assert.deepEqual(recall('abc'), {})
  assert.doesNotThrow(() => remember('abc', { alias: 'Blue Falcon' }))
  assert.doesNotThrow(() => forget('abc'))
})

test('what remember hands back is what was stored', () => {
  remember('abc', { alias: 'Blue Falcon' })
  const merged = remember('abc', { attendeeId: 'att-1' })
  assert.deepEqual(merged, recall('abc'))
})
