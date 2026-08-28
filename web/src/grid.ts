// The week, as a template.
//
// Pointer events are delegated to the container rather than bound per cell:
// there are 672 of them, and one listener that reads `data-slot` is both
// cheaper and the only way drag-painting across cells works at all.

import { html } from 'lit'
import type { TemplateResult } from 'lit'
import { isBusy } from './mask.ts'
import type { Room } from './protocol.ts'
import { columns, slotLabels } from './time.ts'

export type Paint = (slot: number, busy: boolean) => void

// Which way the current drag is painting, or undefined between gestures. It
// lives here rather than in the template because a gesture outlives a render —
// every message from the server redraws the grid mid-drag.
let painting: boolean | undefined

const release = (): void => {
  painting = undefined
}
document.addEventListener('pointerup', release)
document.addEventListener('pointercancel', release)

export function gridView(room: Room, mine: Uint8Array, paint: Paint | undefined): TemplateResult {
  const labels = slotLabels(room.grid)
  const total = room.attendees.length

  const down = (event: PointerEvent): void => {
    const slot = slotOf(event.target)
    if (paint === undefined || slot === undefined) return
    event.preventDefault()
    painting = !isBusy(mine, slot)
    paint(slot, painting)
  }

  const over = (event: PointerEvent): void => {
    const slot = slotOf(event.target)
    if (paint !== undefined && painting !== undefined && slot !== undefined) paint(slot, painting)
  }

  return html`
    <div class="grid" @pointerdown=${down} @pointerover=${over}>
      ${columns(room.grid).map(
        (column) => html`
          <div class="day">
            <h3>${column.label}</h3>
            ${column.slots.map((slot) => cell(room, mine, slot, total, labels[slot] ?? ''))}
          </div>
        `,
      )}
    </div>
  `
}

function cell(
  room: Room,
  mine: Uint8Array,
  slot: number,
  total: number,
  label: string,
): TemplateResult {
  const free = room.heatmap[slot] ?? 0
  const everyone = total > 0 && free === total
  const title = `${label} — ${free} of ${total} free`
  // --weight is the fraction of attendees free here, so the colour is a count
  // and never an identity: it says three people are free, never which three.
  return html`<button
    type="button"
    class="slot ${isBusy(mine, slot) ? 'busy' : ''} ${everyone ? 'everyone' : ''}"
    style="--weight:${total === 0 ? 0 : free / total}"
    data-slot=${slot}
    title=${title}
    aria-label=${title}
  ></button>`
}

function slotOf(target: EventTarget | null): number | undefined {
  if (!(target instanceof HTMLElement)) return undefined
  const slot = target.dataset['slot']
  return slot === undefined ? undefined : Number(slot)
}
