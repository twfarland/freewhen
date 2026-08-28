# 0004. Rooms expire on a timer they own, and finalising shortens it

- Status: Accepted. The deploy consequence below is addressed by
  [0008](0008-rooms-are-resumed-from-the-host-token.md).
- Date: 2026-08-28

## Context

Every room must end. Without a deadline, a scheduling link shared once becomes
a permanent record of who was free when, and the memory it occupies is never
reclaimed — which is also the cheapest denial-of-service available against a
server that holds all its state in RAM.

Two moments matter. A room that nobody ever finishes with should disappear on
its own, and a room where a time *has* been chosen has done its job but still
needs to be readable for long enough that everyone can export the invitation.

## Decision

Every room carries `expires_at`, set at creation from a configured TTL
(24 hours). The value belongs to the domain: `fw_room` refuses every change
once `Now >= expires_at`, and `fw_room_server` sets its timer from
`fw_room:expires_at/1` rather than from configuration, so there is one source
of truth about when a room ends.

When a slot is picked, the room becomes read-only immediately and the timer is
replaced with a shorter grace period (5 minutes). At either deadline the
process stops normally, its entry leaves the directory by the monitor that was
watching it, and connected clients are told `closed`.

A room process is `temporary` under its supervisor and the supervisor's
restart intensity is zero.

## Consequences

Expiry is enforced twice, and deliberately. The timer stops the process, and
the domain independently refuses changes past the deadline — so a room whose
timer is late, or which is examined between the deadline and the message, still
behaves correctly. Neither check is redundant with the other: one reclaims
memory, the other preserves the rule.

`temporary` means a crashed room is not restarted. Restarting would produce an
empty room answering to the same URL, silently dropping everyone who had
already submitted, and a link that stops working is a better failure than one
that lies. Intensity zero means a room ending — which is normal and frequent —
never counts as supervisor churn that could take the runtime down.

Deploying kills every room in progress, since the process is the room. That
was accepted here and is no longer: the participants' own browsers hold enough
to bring the room back at the same address, which is
[0008](0008-rooms-are-resumed-from-the-host-token.md).

The grace period is a guess. Five minutes is long enough to click "add to
calendar" and short enough that a settled room is not a resident. It is
configurable and nothing depends on the specific value.

## Alternatives considered

**Idle timeout — expire when the last watcher leaves.** Attractive for memory,
wrong for the product: someone shares a link, everyone closes their tab, and
the room evaporates before the invitee opens it the next morning.

**Destroy the room the instant a slot is picked**, as the original brief
suggested. Cleanest for retention, but the client needs the picked slot to
build the `.ics`, and a race between "finalise" and "download" would lose the
answer entirely.

**A sweeper process scanning for expired rooms.** One timer per room is simpler,
needs no scan, and puts the deadline where the deadline belongs. The BEAM
handles tens of thousands of timers without noticing.
