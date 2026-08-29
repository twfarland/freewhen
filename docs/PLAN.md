# Plan

## Where this is

A working product, feature-complete as a technical prototype. Create a room,
share the link, join under an alias, set your availability from a preset and
adjust it by dragging or with the keyboard, watch the heatmap update live for
everyone, and have whoever started the room pick a time and export an
invitation. Rooms delete themselves, and neither a release nor a reboot costs
them.

```
rebar3 do compile, eunit, ct, xref, dialyzer   102 unit + 26 integration, clean
cd web && npm run check && npm test             strict tsc, 56 client tests
cd web && npm run build                         ~10 kB gzipped
rebar3 as prod tar                              the deployable artefact, Ubuntu only
```

`docs/ARCHITECTURE.md` describes what exists and why it is shaped that way.
This file is only what is left.

## Next, in order

1. **A real browser, and a real phone.** Unit tests cover the pure modules and
   the reconnection state machine; nothing covers a drag gesture, an `.ics`
   download, or the socket.

   One known-by-inspection defect is fixed but unverified: touch gives the
   first cell implicit pointer capture, so `pointerover` retargeted to it and
   dragging across the grid painted a single square on a phone. `grid.ts` now
   releases the capture, which is the standard fix — but it was reasoned, not
   observed, and it needs a device. If that reasoning is right, the core
   interaction was broken on mobile and nothing in CI would have said so.

   A spring-forward weekend is the other case most likely to be wrong and
   least likely to be caught. Playwright is the obvious tool and a large
   dependency.

2. **Unique aliases, enforced by the server.** The client refuses to join under
   a name already in the room, and that is advisory: two people joining at once
   can still collide, and nothing stops a crafted client. The published
   attendee list deliberately carries no ids, so an alias is the only thing a
   browser can match itself on — which makes uniqueness a domain rule.

   The projection has since been split out into `fw_schedule`, so `fw_room` is
   at 192 lines with room to add the check. Nothing is blocking this now
   except the work: a `taken/2` over the attendee aliases, an `alias_taken`
   error, and the client message to match.

3. **Run the playbook against a real machine.** Every deployment decision is
   reasoned and none has met an actual Ubuntu box. Provision a throwaway
   Hetzner instance, run `site.yml`, then `reboot.yml`, and find out what the
   reasoning missed. Until then the deployment is a design, not a capability.

## Known limits

- **One machine is the capacity and the failure domain.** A room is 2.8 kB for
  an ordinary week, so the 20,000-room ceiling costs about 56 MB in practice
  and 800 MB against crafted input — under the 4 GB the machine has, but no
  longer by a wide margin. Nothing replaces the machine if it dies; someone has
  to notice and re-run the playbook.
- **Durability stops at the disk.** It survives deploys and reboots, not the
  loss of the machine. Resume is the layer beneath, and that needs the host's
  tab open.
- **Room state exists at rest for up to a month.** Aliases and availability in
  one 0700 file, deleted per room the moment the room ends — but a room now
  ends when the meeting is settled or after a month idle, not within a day.
  That is a materially longer exposure than the original design had, and it is
  the honest cost of letting coordination take as long as it really takes.
- **An unattended-upgrades reboot is a restart**, at 04:00 UTC, and only
  affordable because of the snapshot.
- **Anyone with a room link can join under any alias**, and can join twice on
  purpose to weight the counts. Same trust model as a shared document link;
  the attendee cap and the 24-hour life bound it.
- **The exported invitation puts the room hash in a jit.si URL.** Anyone
  holding the `.ics` — and jit.si itself, once someone clicks — learns the
  room's address. The room dies a day after a time is picked, so the capability
  is nearly spent, but it is a disclosure and the provider is hardcoded. A
  product decision worth re-taking.
- **The server is not zero-knowledge**, and the README no longer implies it is.
  It holds each person's availability in order to add it up. What is true is
  that no participant receives another's row, that it is never logged, and that
  nothing outlives the room.
- **Nobody sees what a slot means for anyone else.** Everyone reads the grid in
  their own timezone. That was briefly built and removed with the timezone
  field.
