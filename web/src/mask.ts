// The busy bits, as the wire wants them.
//
// The server's domain holds availability as a set of slots, because that is
// what it means. The wire packs it one bit per slot — eighty-four bytes for a
// week against two and a half kilobytes as a list of numbers — and this is the
// browser's half of that translation.
//
// Bits are most-significant first within each byte, matching Erlang's
// `<<Bit:1>>` bitstring layout on the other side.

import type { Grid } from './protocol.ts'
import { slotAt } from './time.ts'

const WORKDAY_START = 9 * 60
const WORKDAY_END = 17 * 60

export function emptyMask(grid: Grid): Uint8Array {
  return new Uint8Array((grid.slots + 7) >> 3)
}

export function setSlot(mask: Uint8Array, slot: number, busy: boolean): void {
  const byte = slot >> 3
  const bit = 0x80 >> (slot & 7)
  const current = mask[byte] ?? 0
  mask[byte] = busy ? current | bit : current & ~bit
}

export function isBusy(mask: Uint8Array, slot: number): boolean {
  return ((mask[slot >> 3] ?? 0) & (0x80 >> (slot & 7))) !== 0
}

export function encodeMask(mask: Uint8Array): string {
  let binary = ''
  for (const byte of mask) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')
}

/** Read back what this browser stored. A mask of the wrong width is discarded. */
export function decodeMask(encoded: string, grid: Grid): Uint8Array | undefined {
  try {
    const binary = atob(encoded.replaceAll('-', '+').replaceAll('_', '/'))
    const mask = Uint8Array.from(binary, (character) => character.charCodeAt(0))
    return mask.length === (grid.slots + 7) >> 3 ? mask : undefined
  } catch {
    return undefined
  }
}

export type Preset = 'weekdays' | 'clear' | 'all'

/**
 * A starting point, so nobody has to paint a whole week.
 *
 * `weekdays` marks everything outside Monday to Friday, 9 to 5 local, as busy —
 * most people's answer most of the time, leaving a handful of exceptions.
 * Read from each slot's own local time, so a week spanning a clock change is
 * still right on both sides of it.
 */
export function preset(grid: Grid, kind: Preset): Uint8Array {
  const mask = emptyMask(grid)
  if (kind === 'clear') return mask
  for (let slot = 0; slot < grid.slots; slot++) {
    setSlot(mask, slot, kind === 'all' || !isWorkingHour(grid, slot))
  }
  return mask
}

function isWorkingHour(grid: Grid, slot: number): boolean {
  const at = new Date(slotAt(grid, slot))
  const weekday = at.getDay()
  const minutes = at.getHours() * 60 + at.getMinutes()
  const isWeekday = weekday >= 1 && weekday <= 5
  return isWeekday && minutes >= WORKDAY_START && minutes < WORKDAY_END
}
