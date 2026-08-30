// The week, as a template.
//
// Pointer events are delegated to the container rather than bound per cell:
// there are hundreds of them, and one listener is both cheaper and the only
// way a drag across cells works at all. The container takes pointer capture on
// the way down and every later position is resolved with elementFromPoint —
// reading `event.target` instead looks like it works with a mouse and fails on
// touch, where the first cell keeps implicit capture and a drag paints one
// square.
//
// Every cell is a real <button> with a roving tabindex, so the whole grid is
// one tab stop and the arrow keys move within it. Dragging is a pointer
// gesture and cannot be the only way to answer: a keyboard has to be able to
// say the same things, and space says them one cell at a time while
// shift+arrow says them in runs.

import { html, nothing } from 'lit'
import type { TemplateResult } from 'lit'
import { isFree } from './mask.ts'
import type { Hours } from './hours.ts'
import { destination, locate } from './navigate.ts'
import type { Room } from './protocol.ts'
import { columns, hourMarks, slotLabels, withinHours } from './time.ts'

export type Paint = (slot: number, free: boolean) => void

// A gesture outlives a render — every message from the server redraws the grid
// mid-drag — so both of these live here rather than in the template. `painting`
// is which way the current drag is going, or undefined between gestures;
// `focused` is the grid's single tab stop.
let painting: boolean | undefined
let painted: number | undefined
let focused = 0

const release = (): void => {
  painting = undefined
  painted = undefined
}
document.addEventListener('pointerup', release)
document.addEventListener('pointercancel', release)

export function gridView(
  room: Room,
  mine: Uint8Array,
  hours: Hours,
  paint: Paint | undefined,
): TemplateResult {
  const labels = slotLabels(room.grid)
  const marks = hourMarks(room.grid)
  const within = withinHours(room.grid, hours)
  const days = columns(room.grid)
  const total = room.attendees.length
  // Which slots the settled meeting occupies, so a grid that is still open for
  // changes says where the thing being changed actually is.
  const chosen = room.chosen
  const meeting =
    chosen === null ? undefined : { from: chosen.slot, to: chosen.slot + room.durationSlots }

  // A pointer moving quickly reports positions several cells apart, so
  // painting only what is under it leaves gaps. Fill from the last cell to
  // this one, but only within a day — consecutive slot numbers run down a
  // column, so spanning two columns would paint everything between them.
  const sweep = (to: number): void => {
    const from = painted
    painted = to
    if (paint === undefined || painting === undefined) return
    const here = locate(days, to)
    const before = from === undefined ? undefined : locate(days, from)
    if (from === undefined || before === undefined || here === undefined) {
      paint(to, painting)
      return
    }
    if (before.day !== here.day) {
      paint(to, painting)
      return
    }
    for (let slot = Math.min(from, to); slot <= Math.max(from, to); slot++) {
      paint(slot, painting)
    }
  }

  const down = (event: PointerEvent): void => {
    const slot = under(event)
    if (paint === undefined || slot === undefined) return
    event.preventDefault()
    if (event.currentTarget instanceof Element) {
      event.currentTarget.setPointerCapture(event.pointerId)
    }
    painting = !isFree(mine, slot)
    painted = slot
    paint(slot, painting)
  }

  // Coalesced events are the positions the browser buffered between frames;
  // without them a fast drag is sampled once per frame and misses cells.
  const move = (event: PointerEvent): void => {
    if (paint === undefined || painting === undefined) return
    for (const step of event.getCoalescedEvents?.() ?? [event]) {
      const slot = under(step)
      if (slot !== undefined) sweep(slot)
    }
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
      @pointermove=${move}
      @keydown=${key}
    >
      ${days.map(
        (column) => html`
          <div class="day">
            <h3>${column.label}</h3>
            <div class="slots">
              ${column.slots.map(
                (slot) => html`
                  <span class="hour" aria-hidden="true">${marks[slot] ?? ''}</span>
                  ${cell({
                    room,
                    mine,
                    slot,
                    total,
                    label: labels[slot] ?? '',
                    within: within[slot] ?? true,
                    meeting,
                  })}
                `,
              )}
            </div>
          </div>
        `,
      )}
    </div>
  `
}

type Cell = {
  room: Room
  mine: Uint8Array
  slot: number
  total: number
  label: string
  within: boolean
  meeting: { from: number; to: number } | undefined
}

function cell({ room, mine, slot, total, label, within, meeting }: Cell): TemplateResult {
  const free = room.heatmap[slot] ?? 0
  const title = `${label} — ${free} of ${total} free`
  const settled = meeting !== undefined && slot >= meeting.from && slot < meeting.to
  // --weight is the fraction of attendees free here, so the tone is a count
  // and never an identity: it says three people are free, never which three.
  return html`<button
    type="button"
    class="slot ${isFree(mine, slot) ? 'mine' : ''} ${within ? '' : 'off'} ${
      settled ? 'chosen' : ''
    }"
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

// Whatever is under the pointer right now, capture or not.
function under(event: PointerEvent): number | undefined {
  return slotOf(document.elementFromPoint(event.clientX, event.clientY))
}

function slotOf(target: EventTarget | null): number | undefined {
  if (!(target instanceof HTMLElement)) return undefined
  const slot = target.dataset['slot']
  return slot === undefined ? undefined : Number(slot)
}
