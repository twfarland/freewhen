// Where an arrow key goes, given how the week fell into local days.
//
// Separate from grid.ts because that module attaches a document listener when
// it loads and so cannot be imported outside a browser. This is the part with
// edges worth checking — the ends of a day, the ends of the week, and the two
// days a year that are not twenty-four hours long — and it is a pure function
// of the layout.

export type Day = { slots: number[] }

export type Position = { day: number; index: number }

/** Where a key would take you, or undefined if it would take you nowhere. */
export function destination(days: Day[], from: number, key: string): number | undefined {
  const at = locate(days, from)
  if (at === undefined) return undefined
  const { day, index } = at
  switch (key) {
    case 'ArrowUp':
      return days[day]?.slots[index - 1]
    case 'ArrowDown':
      return days[day]?.slots[index + 1]
    // Days are not all the same length — the two clock changes see to that —
    // so moving sideways lands on the nearest time that day actually has.
    case 'ArrowLeft':
      return alongside(days[day - 1], index)
    case 'ArrowRight':
      return alongside(days[day + 1], index)
    case 'Home':
      return days[day]?.slots[0]
    case 'End':
      return days[day]?.slots.at(-1)
    default:
      return undefined
  }
}

export function locate(days: Day[], slot: number): Position | undefined {
  for (const [day, column] of days.entries()) {
    const index = column.slots.indexOf(slot)
    if (index !== -1) return { day, index }
  }
  return undefined
}

function alongside(day: Day | undefined, index: number): number | undefined {
  if (day === undefined) return undefined
  return day.slots[Math.min(index, day.slots.length - 1)]
}
