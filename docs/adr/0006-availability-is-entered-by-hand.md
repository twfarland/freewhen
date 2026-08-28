# 0006. Availability is entered by hand, not imported

- Status: Accepted
- Date: 2026-08-28

## Context

The original brief positioned FreeWhen against Doodle and When2meet on the
grounds that they "force manual, tedious slot-painting", and proposed solving
that with client-side calendar sync: Google's free/busy API through an OAuth
popup, or a dropped `.ics` file parsed in the browser.

The `.ics` half was built — around 180 lines handling folding, `DTSTART`,
`DTEND`, `DURATION`, `EXDATE`, and daily and weekly recurrence — and worked.
Using it is where the problem showed up.

Getting an `.ics` file out of a calendar is worse than painting a week. Google
Calendar's export produces a **zip of every calendar you own, in full**, which
you then unzip and pick a file from. Apple Calendar and Thunderbird export
everything too. Only Outlook desktop offers a date range. For a question that
takes thirty seconds to answer by dragging, that is a trip through a settings
menu.

The parser was also incomplete in a way users could not see. Monthly and yearly
recurrence contributed a single occurrence, and a `TZID` we had no timezone
database for was read as local time. Both failure modes report someone as
*free* when they are busy, silently, and the person whose availability is wrong
is not the person reading the grid.

## Decision

There is no calendar integration of any kind. Availability is entered in the
browser by dragging across the grid, starting from a preset.

Three presets, in `fw_mask` on the client: **only weekdays 9–5** (busy
everywhere else, which is most people's answer most of the time), **free all
week**, and **busy all week**. The expected interaction is one click then a
handful of corrections.

`web/src/ics.ts` is deleted rather than disabled.

## Consequences

The client loses about 180 lines, one whole category of silent wrongness, and
its only piece of format-parsing. Nothing in the system now interprets anything
more complicated than a bitmask.

The privacy story gets simpler to state and to verify. Previously it was "your
calendar is parsed locally and only bits are sent", which asks the reader to
trust a claim about code they have not read. Now it is "there is no calendar
input", which is not a claim about behaviour at all.

Someone with a genuinely back-to-back week has more painting to do. The
weekday preset covers the common shape — free during working hours, busy
outside them — so the work is proportional to how unusual the week is, which is
the right shape. If this turns out to be the complaint, `.ics` returns as one
self-contained module producing `Interval[]`, and the mask layer already
accepts exactly that.

The product is no longer differentiated from When2meet by convenience. What
distinguishes it is that rooms self-destruct and that the server only ever
holds counts, never who is free when. That is a narrower pitch and an honest
one.

## Alternatives considered

**Keep `.ics`, add Google.** The brief's plan. Google's `freeBusy` endpoint is
genuinely good — it returns already-expanded busy intervals, so it needs no
recurrence handling at all. It also needs an OAuth client id, a consent screen,
a registered origin, and a third-party dependency in a product whose entire
claim is that it depends on nobody. Rejected on that alone.

**Keep `.ics`, drop Google.** Tempting, since the code existed and passed its
tests. Rejected because export friction makes it slower than painting for most
calendars, and because a parser that silently understates how busy someone is
does more harm than not having one.

**A server-side fetch of a published calendar URL.** Convenient, and it would
hand the server everyone's full calendar. The opposite of the product.
