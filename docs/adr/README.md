# Architecture decision records

One page each, in the order they were taken. A record is never rewritten to say
something different — it is superseded by a later one, and the old body stays
as the account of what we believed and why. See
`.claude/skills/adr/SKILL.md` for the format and when a new record is required.

| # | Decision | Status |
|---|---|---|
| [0001](0001-no-database-rooms-live-in-ram.md) | No database: a room lives in RAM and dies there | Superseded by [0011](0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md) |
| [0002](0002-three-layers-with-a-pure-domain.md) | Three layers, with a pure domain that cannot read a clock | Accepted |
| [0003](0003-a-plain-json-protocol-over-one-websocket.md) | A plain JSON protocol over one websocket, and a plain TypeScript client | Accepted |
| [0004](0004-rooms-expire-on-a-timer-they-own.md) | Rooms expire on a timer they own, and finalising shortens it | Accepted |
| [0005](0005-secrets-are-capabilities-not-accounts.md) | Secrets are capabilities: no accounts, no recovery | Accepted |
| [0006](0006-availability-is-entered-by-hand.md) | Availability is entered by hand, not imported | Accepted |
| [0007](0007-the-client-renders-with-lit-templates.md) | The client renders with Lit templates | Accepted |
| [0008](0008-rooms-are-resumed-from-the-host-token.md) | Rooms are resumed from the host token, not preserved on disk | Accepted |
| [0009](0009-the-server-decides-the-browser-formats.md) | The server decides, the browser formats — and keeps each attendee's timezone | Superseded by [0010](0010-the-server-holds-no-timezone.md) |
| [0010](0010-the-server-holds-no-timezone.md) | The server holds no timezone | Accepted |
| [0011](0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md) | A local DETS snapshot, so a restart keeps the rooms | Accepted |
| [0012](0012-one-instance-and-what-more-would-take.md) | One instance, and what more would take | Accepted |
