// This browser's own answer, as the bits the wire wants.
//
// One bit per slot, set means free. The server takes these, turns them into
// slot numbers, and `fw_availability` merges them into stretches — so the
// domain never sees a bit and this file never sees a stretch.
//
// Bits are most-significant first within each byte, matching Erlang's
// `<<Bit:1>>` bitstring layout on the other side.

import { DEFAULT_HOURS } from './hours.ts'
import type { Hours } from './hours.ts'
import type { Grid } from './protocol.ts'
import { slotAt } from './time.ts'

/** Free nowhere, which is what somebody who has said nothing means. */
export function emptyMask(grid: Grid): Uint8Array {
  return new Uint8Array((grid.slots + 7) >> 3)
}

export function setSlot(mask: Uint8Array, slot: number, free: boolean): void {
  const byte = slot >> 3
  const bit = 0x80 >> (slot & 7)
  const current = mask[byte] ?? 0
  mask[byte] = free ? current | bit : current & ~bit
}

export function isFree(mask: Uint8Array, slot: number): boolean {
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

export type Preset = 'weekdays' | 'always' | 'never'

/**
 * A starting point, so nobody has to paint a whole week.
 *
 * `weekdays` offers Monday to Friday within `hours` local — most people's
 * answer most of the time, leaving a handful of exceptions to remove. Read
 * from each slot's own local time, so a week spanning a clock change is right
 * on both sides of it.
 */
export function preset(grid: Grid, kind: Preset, hours: Hours = DEFAULT_HOURS): Uint8Array {
  const mask = emptyMask(grid)
  if (kind === 'never') return mask
  for (let slot = 0; slot < grid.slots; slot++) {
    setSlot(mask, slot, kind === 'always' || isWorkingHour(grid, slot, hours))
  }
  return mask
}

function isWorkingHour(grid: Grid, slot: number, hours: Hours): boolean {
  const at = new Date(slotAt(grid, slot))
  const weekday = at.getDay()
  const minutes = at.getHours() * 60 + at.getMinutes()
  const isWeekday = weekday >= 1 && weekday <= 5
  return isWeekday && minutes >= hours.start && minutes < hours.end
}
