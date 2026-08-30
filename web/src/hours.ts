// A person's working day, as minutes from local midnight.
//
// Separate from mask.ts because that file is about bits and this is about a
// preference: the weekday preset is only useful to somebody whose week is
// Monday to Friday nine to five, and plenty of people's is not. It is stored
// per room in this browser and never sent anywhere — the server has no field
// for it and should not.

export type Hours = { start: number; end: number }

export const DEFAULT_HOURS: Hours = { start: 9 * 60, end: 17 * 60 }

/** An end at or before its start would select nothing, which is never meant. */
export function areHours(value: unknown): value is Hours {
  if (typeof value !== 'object' || value === null) return false
  const { start, end } = value as Partial<Hours>
  if (typeof start !== 'number' || typeof end !== 'number') return false
  return Number.isInteger(start) && Number.isInteger(end) && start >= 0 && start < end && end <= 1440
}

/** Minutes to the `HH:MM` an <input type="time"> wants. */
export function asClock(minutes: number): string {
  const hour = Math.floor(minutes / 60)
  return `${String(hour).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`
}
