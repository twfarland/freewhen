# FreeWhen

Find a time to meet with people outside your organisation, without either side
signing up for anything or leaving a record.

Everyone marks when they are busy, as one bit per fifteen minutes. The server
intersects the bits in memory, shows how many people are free in each slot —
never which people — and deletes the room when it is done. There is no
database, so there is nothing to leak, export, subpoena or forget to delete.

## How it works

1. Someone creates a room and gets a link. No account.
2. Everyone opens the link and picks a name others will recognise —
   "Blue Falcon", not their own.
3. Each person clicks a preset — "only weekdays 9–5" is usually right — then
   drags across the grid to fix the exceptions. Only a bitmask is sent.
4. The heatmap shows how many people are free in each slot, in each viewer's
   own timezone. It never shows *which* people. Every suggested time is
   labelled in everyone's local time, so nobody has to do the arithmetic.
5. Whoever created the room picks a slot and everyone downloads an invitation
   with a video link in it.
6. The room deletes itself — minutes after a time is chosen, or 24 hours after
   it was created, whichever comes first. Deploying the server does not count:
   rooms are snapshotted locally so a release does not take them with it.

## What the server never sees

Your email address, your name, or your calendar. There is no calendar
integration at all — no API, no file import — so there is no claim about
calendar data for you to have to trust.

It does keep **your timezone**, because scheduling across timezones needs it:
"Tuesday at 10:00" is not an answer when half the room is on another continent.
That is the only thing it knows about a person, it is weaker than the IP
address your connection already reveals, and it is gone with the room.

Everything the server holds is a random room hash, a chosen alias per person,
and a set of busy slots. It is kept in RAM, and mirrored to one local file so
that deploying does not destroy your meeting — that file is deleted per room
the moment the room ends, and nothing in it outlives the day. It is the only
thing written anywhere.

It also never learns *who* is free when. Every watcher sees how many people are
free in a slot and nothing more, which is the one thing When2meet and Doodle
will always tell you.

## Running it

Needs Erlang/OTP 27, rebar3 and Node 22.

```sh
cd web && npm ci && npm run build   # build the client
cd .. && rebar3 shell               # http://localhost:8080
```

## Checks

```sh
rebar3 do compile, eunit, ct, xref, dialyzer
cd web && npm run check
```

Warnings are errors, every export has a spec, and dialyzer and xref must be
clean. 90 unit tests and 18 integration tests over real sockets.

## Deploying

```sh
fly deploy
```

A deploy destroys every room process, and the rooms come back by themselves:
a room's address is derived from its host's token, so the host's browser
reopens it and everyone resubmits what their own browser was holding. Nothing
is written to disk to make that work.

One machine, deliberately — a room lives in the memory of the process that
created it. Set `FW_ALLOWED_ORIGINS` before making a deployment public. See
[docs/OPERATIONS.md](docs/OPERATIONS.md).

## Reading it

| | |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | the three layers, what each owns, and the protocol |
| [docs/PLAN.md](docs/PLAN.md) | what is built, what is next, and the known limits |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | running, deploying, and what failure looks like |
| [docs/adr/](docs/adr/) | the decisions, and what each one cost |
| [CLAUDE.md](CLAUDE.md) | the rules the code is held to |

About 1,170 lines of Erlang and 735 of TypeScript, plus 815 lines of tests.
Two dependencies: cowboy on the server, Lit in the browser. Staying that size
is the design constraint, not a stage it is passing through.
