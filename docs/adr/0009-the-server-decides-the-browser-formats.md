# 0009. The server decides, the browser formats — and keeps each attendee's timezone

- Status: Superseded by [0010](0010-the-server-holds-no-timezone.md). The
  server/browser split below stands; collecting a timezone does not.
- Date: 2026-08-28

## Context

The client had drifted into doing arithmetic. It turned slot numbers into
instants, grouped slots into local days, and worked out what a proposal meant —
all of which are questions the server had already answered or could answer
better. That is the failure mode a browser client falls into when the server
sends it raw state, and it puts the same logic in two places written in two
languages.

Ephemeral server-side state is the reason to use the BEAM at all. A room is a
supervised process holding everything about itself; there is no reason for a
browser to recompute any part of it.

Cutting against that: the product schedules across timezones, and rendering an
instant in a named zone needs the IANA timezone database. Every browser ships
one. The BEAM ships none, and the Erlang packages that provide one unpack the
database onto disk — in an application whose claim is that it writes nothing.

Until now the server did not know anyone's timezone, and each browser rendered
only its own local time. That makes a proposal unreadable to the person it most
concerns: "Tuesday at 10:00" is not an answer when half the room is on another
continent.

## Decision

**The server owns every domain fact. The browser owns formatting, and nothing
else.**

The server computes and publishes the heatmap, the ranked proposals, whether
each attendee has answered, whether the room is settled, and when it ends.
Proposals and the chosen slot carry their **UTC start and end instants**, not
slot numbers, so the client never converts anything.

**Each attendee's IANA timezone is part of the room.** It is collected on join
from `Intl.DateTimeFormat().resolvedOptions().timeZone`, validated for shape,
stored beside the alias, and published to every watcher. Browsers use it to
show every proposal in every participant's local time.

The server stores instants in UTC exclusively. A timezone is a display label
and is never used in a calculation server-side.

## Consequences

The client stops holding opinions. `view.ts` and `grid.ts` are functions from
the published room to a template; the only arithmetic left is turning the
grid's `startsAt` and `slotMinutes` into one instant per cell, which is layout,
not scheduling. Everything that decides anything is in `fw_core`, tested by
unit tests that need no browser.

Cross-timezone scheduling actually works. A proposal now reads "Tuesday 10:00 —
21:00 Pacific/Auckland · 05:00 America/New_York", which is the thing the
product is for and which no amount of local-time rendering could produce.

**We now hold a piece of information about people, and that is a real change.**
A timezone narrows someone to a longitude band. It is far weaker than a
calendar and weaker than the IP address the connection already reveals, it
lives in RAM for at most a day like everything else, and the product cannot do
its job without it. But "the server knows nothing about you" is no longer
literally true, and the README says so rather than glossing it.

We keep a dependency out of the release. No timezone database, no CLDR, no disk
writes, and no quarterly scramble when the IANA database changes — browsers
update themselves.

The split has one soft edge: what counts as "formatting" is a judgement. The
rule applied here is that the server answers questions about the *meeting* and
the browser answers questions about the *reader*. Local day grouping and clock
formatting are about the reader; who is free when is about the meeting.

## Alternatives considered

**Send an offset in minutes instead of a zone name.** No database needed on
either side, and simple integer arithmetic on the server. Rejected because an
offset captured today is wrong for a slot ten days out across a clock change,
which is exactly when a week-long grid is being used.

**Add a timezone database to the server and render strings there.** The purest
reading of "all state computed on the server". Rejected on the disk write
alone, and it would also mean the server choosing a locale for people it knows
nothing about.

**Keep the server timezone-blind and render only local time.** What we had. It
is the strongest privacy position and it makes the product worse at the one
thing it exists for.
