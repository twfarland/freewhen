# 0010. The server holds no timezone

- Status: Accepted
- Date: 2026-08-29
- Supersedes: [0009](0009-the-server-decides-the-browser-formats.md)

## Context

[0009](0009-the-server-decides-the-browser-formats.md) made two decisions at
once and only one of them was right.

The first — the server computes every domain fact and the browser only formats —
holds, and this record keeps it. Proposals carry UTC start and end instants so
that no arithmetic happens client-side.

The second was to collect each attendee's IANA timezone, store it beside their
alias, and publish it, so that browsers could render a proposal in everyone's
local time. The reasoning was that the browser needs a name to convert against.
That is true of *someone else's* timezone. It is not true of your own, which
the browser already knows and can canonicalise to and from UTC without the
server ever hearing about it.

So the server was collecting something it did not need in order for each person
to read the grid correctly, in exchange for a feature — showing every
participant what a slot means for the others — that was never asked for.

## Decision

The server holds no timezone for anybody. `fw_timezone` is deleted, `join`
carries only an alias, and no attendee record has a location of any kind.

Every instant the server holds is UTC. Each browser converts to and from UTC
against its own locale, and displays only its own local time.

The half of 0009 that stands: the server computes the heatmap, the ranked
proposals with their UTC instants, who has answered and whether the room is
settled. The browser formats and does no arithmetic beyond laying the grid out
into local days.

## Consequences

"The server knows nothing about you" is literally true again, which is the
sentence the product is built to be able to say. There is no field for a
location, so there is nothing to leak, subpoena, or reason about — a stronger
position than any policy about a field that exists.

Everyone still reads the grid correctly in their own timezone, because that was
always the browser's job and the browser always had what it needed.

We lose showing a proposal in *other* participants' local times. That is a
genuine feature for a cross-timezone meeting and it is gone; a host in London
proposing 17:00 will not be told it is 05:00 in Auckland. Nobody asked for it,
and buying it with a stored location was the wrong trade.

If it is ever wanted, it does not require the server. A client already knows
its own zone and could send the *offset it computes for each proposal* as
display data — or participants could simply say where they are in their alias.
Neither needs a field on the attendee record.

`fw_attendee` is smaller, `fw_room:join/4` lost an argument, and a value object
and its tests are deleted.

## Alternatives considered

**Keep the timezone and treat it as acceptable.** It is weaker than the IP the
connection reveals and it dies with the room, so the risk was small. Rejected
because "small" is a judgement that has to be re-made by every reader, whereas
"the field does not exist" is checkable in ten seconds.

**Collect the timezone but never publish it.** Pointless: it would be held for
nothing, since only other people's browsers could use it.
