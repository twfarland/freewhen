// The week, as a template.
//
// Pointer events are delegated to the container rather than bound per cell:
// there are 672 of them, and one listener that reads `data-slot` is both
// cheaper and the only way drag-painting across cells works at all.
//
// Every cell is a real <button> with a roving tabindex, so the whole grid is
// one tab stop and the arrow keys move within it. Dragging is a pointer
// gesture and cannot be the only way to answer: a keyboard has to be able to
// say the same things, and space says them one cell at a time while
// shift+arrow says them in runs.

import { html } from 'lit'
import type { TemplateResult } from 'lit'
import { isFree } from './mask.ts'
import { destination } from './navigate.ts'
import type { Room } from './protocol.ts'
import { columns, slotLabels } from './time.ts'

export type Paint = (slot: number, free: boolean) => void

// A gesture outlives a render — every message from the server redraws the grid
// mid-drag — so both of these live here rather than in the template. `painting`
// is which way the current drag is going, or undefined between gestures;
// `focused` is the grid's single tab stop.
let painting: boolean | undefined
let focused = 0

const release = (): void => {
  painting = undefined
}
document.addEventListener('pointerup', release)
document.addEventListener('pointercancel', release)

export function gridView(room: Room, mine: Uint8Array, paint: Paint | undefined): TemplateResult {
  const labels = slotLabels(room.grid)
  const days = columns(room.grid)
  const total = room.attendees.length

  const down = (event: PointerEvent): void => {
    const slot = slotOf(event.target)
    if (paint === undefined || slot === undefined) return
    event.preventDefault()
    // Touch gives the first cell implicit pointer capture, so without this
    // every later pointerover retargets to that cell and a drag paints one
    // square. Releasing it lets the events land on whatever is under the
    // finger, which is what the mouse already does.
    if (event.target instanceof Element && event.target.hasPointerCapture(event.pointerId)) {
      event.target.releasePointerCapture(event.pointerId)
    }
    painting = !isFree(mine, slot)
    paint(slot, painting)
  }

  const over = (event: PointerEvent): void => {
    const slot = slotOf(event.target)
    if (paint !== undefined && painting !== undefined && slot !== undefined) paint(slot, painting)
  }

  const key = (event: KeyboardEvent): void => {
    const from = slotOf(event.target)
    if (from === undefined) return

    if (event.key === ' ' || event.key === 'Enter') {
      event.preventDefault()
      paint?.(from, !isFree(mine, from))
      return
    }

    const to = destination(days, from, event.key)
    if (to === undefined) return
    event.preventDefault()
    // Shift extends: the destination takes the value the anchor already has,
    // which is what dragging does and what selecting a run should feel like.
    if (event.shiftKey) paint?.(to, isFree(mine, from))
    focus(event.currentTarget, to)
  }

  return html`
    <div
      class="grid"
      role="group"
      aria-label="Availability for the week. Arrow keys to move, space to toggle, shift and arrow to extend."
      @pointerdown=${down}
      @pointerover=${over}
      @keydown=${key}
    >
      ${days.map(
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
    class="slot ${isFree(mine, slot) ? 'mine' : ''} ${everyone ? 'everyone' : ''}"
    style="--weight:${total === 0 ? 0 : free / total}"
    data-slot=${slot}
    tabindex=${slot === focused ? 0 : -1}
    aria-pressed=${isFree(mine, slot)}
    title=${title}
    aria-label=${title}
  ></button>`
}

function focus(container: EventTarget | null, to: number): void {
  if (!(container instanceof HTMLElement)) return
  const target = container.querySelector<HTMLButtonElement>(`[data-slot="${to}"]`)
  if (target === null) return
  const leaving = container.querySelector<HTMLButtonElement>(`[data-slot="${focused}"]`)
  if (leaving !== null) leaving.tabIndex = -1
  focused = to
  target.tabIndex = 0
  target.focus()
}

function slotOf(target: EventTarget | null): number | undefined {
  if (!(target instanceof HTMLElement)) return undefined
  const slot = target.dataset['slot']
  return slot === undefined ? undefined : Number(slot)
}
