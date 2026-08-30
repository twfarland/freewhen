# FreeWhen

Find a time to meet with people outside your organisation, without either side
signing up for anything or leaving a record.

Everyone drags across a grid to say when they are free. The server intersects
the answers in memory and shows how many people are free in each slot, but not
who they are. There are no accounts, no database and no calendar integration.
Meeting data is removed when the room expires or the host deletes it.

> **Status: working prototype.** Every check below is green and it has been
> tested end to end in a real browser. The production deployment has not yet
> been tested on a live server. See [docs/PLAN.md](docs/PLAN.md) for the
> remaining work and known limitations.

## How it works

1. Someone starts a meeting and gets a link. No account.
2. Everyone opens the link and picks a name others will recognise, such as
   "Blue Falcon", not their own.
3. Each person starts with a preset such as "weekdays 9–5", then drags across the grid
   to fix the exceptions, or arrows around it and presses space. Only packed
   bits go over the wire.
4. The heatmap shows how many people are free in each slot, in each viewer's
   own timezone. It never shows *which* people. Every suggested time is
   labelled in everyone's local time, so nobody has to do the arithmetic.
5. **Once everybody has answered**, whoever started the meeting picks a time
   and everyone downloads an invitation. Not before: choosing while somebody is
   still deciding is how a meeting gets booked over the one person who could
   not make it. If somebody opened the link and went away, the host can go
   ahead without them. Nobody has to be named to do it.
6. **A chosen time is an answer, not an ending.** Plans change, so the host can
   move it, and anyone whose availability changes invalidates it automatically:
   the meeting simply starts saying "only 3 of 4 can make this". There is no
   separate acceptance step. People can RSVP through the exported calendar
   invitation.
7. The host can call the whole thing off, which deletes it for everyone at
   once. Otherwise the room deletes itself a day after the meeting it
   scheduled, or after a month with nobody touching it. Every change resets
   that month. This gives groups enough time to arrange meetings that take
   several weeks to coordinate.
   Deploying the server does not count: rooms are snapshotted locally so a
   release does not take them with it.

## What the server never sees

Your email address, your name, or your calendar. There is no calendar
integration at all: no API and no file import. You do not have to grant access
to any calendar data.

Not even your timezone. Every instant it holds is UTC, and turning one into
"Tuesday at 10:00" happens in your browser against your own locale, so there is
nothing on the server that says where anybody is.

**No third party sees anything either.** The page makes no requests off the
origin: no analytics, no CDN, no font service. The two typefaces are served
from the same host, because loading them from Google would hand every visitor's
address to Google.

The server holds a random room hash, each person's chosen alias, and the times
they marked as free. This data is kept in RAM and copied to one local file so a
deployment or reboot does not lose active meetings. Each room's data is deleted
when that room ends.

A room remains available until a day after the scheduled meeting, or until it
has gone untouched for a month. Choosing a time does not immediately close the
room, so the host can move it if plans change.

**No other participant** learns who is free when. The server must hold each
person's answer to calculate the totals, so this is not a zero-knowledge
system. Individual availability is not published or logged, and the server
removes it when the room ends. Everyone in the room, including the host, sees
only how many people are free in each slot.

## Running it

Needs Erlang/OTP 27, rebar3 and Node 22. No additional services or containers
are required.

```sh
cd web && npm ci && npm run watch   # terminal 1: rebuild the client on save
rebar3 shell                        # terminal 2: http://localhost:8080
```

Open the room link in a second browser profile to be a second person.
Recompile a server change from inside the shell with `r3:do(compile)`, which
swaps the changed modules into the running node. Rooms live in the shell's
memory and go when it does. [docs/DEVELOPING.md](docs/DEVELOPING.md) has the
rest, including how to exercise the durability path locally.

## Checks

```sh
rebar3 do compile, eunit, ct, xref, dialyzer
cd web && npm run check && npm test
escript bench/load.escript            # fill it to the room ceiling and measure
```

Warnings are errors, every export has a spec, and dialyzer and xref must be
clean. **148 unit tests and 32 integration tests over real sockets** on the
server, **58 in the browser** with no test framework. A hook refuses any module
over 200 lines, any function over 30, and any dependency that points the wrong
way between layers.

## Deploying

One Hetzner box, no containers, one Ansible playbook that provisions the
machine and ships to it.

```sh
cd web && npm ci && npm run build && cd ..
rebar3 as prod tar
ansible-playbook -i deploy/inventory.ini deploy/site.yml
```

Caddy gets the certificate, systemd keeps the node up, `unattended-upgrades`
patches the OS, and `ufw` closes everything else. Everything is enabled at
boot, so the machine starts on its own after a reboot. `deploy/reboot.yml`
checks this. The release bundles its own ERTS, so the server needs no Erlang
installed, but it must be built on the same Ubuntu; both CI and the playbook
check that.

`--tags reload` swaps changed modules into the running node without dropping a
socket, for a hotfix worth not interrupting anyone over.

A deploy stops the node and starts it again. The rooms survive because they are
snapshotted locally and read back before the listener opens; if that file is
gone, a room's address is derived from its host's token, so the host's browser
reopens it and everyone resubmits what their own browser held.

FreeWhen runs on one machine because each room lives in the memory of the
process that created it. See [docs/OPERATIONS.md](docs/OPERATIONS.md) for
operational details.

## Reading it

| | |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | the layers, the supervision tree, the state machine, the protocol, and every decision |
| [docs/DEVELOPING.md](docs/DEVELOPING.md) | the local loop, the checks, and the guardrails |
| [docs/PLAN.md](docs/PLAN.md) | what is built, what is next, and the known limits |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | deploying, watching, and what failure looks like |
| [CLAUDE.md](CLAUDE.md) | the rules the code is held to |

About 2,300 lines of Erlang and 1,500 of TypeScript, against 2,150 lines of
test and 460 of Ansible. Two runtime dependencies: cowboy on the server, Lit in
the browser. Keeping the system small is an ongoing design constraint.

## Licence

[MIT](LICENSE), except the two typefaces in
`apps/fw_web/priv/static/fonts/`, which are Newsreader and Archivo under the
SIL Open Font License 1.1. See
[the licence bundled with them](apps/fw_web/priv/static/fonts/OFL.txt).
