# FreeWhen

Find a time to meet with people outside your organisation, without either side
signing up for anything or leaving a record.

Everyone drags across a grid to say when they are free. The server intersects
the answers in memory and shows how many people are free in each slot — never
which people. There are no accounts, no database and no calendar integration,
and nothing about a meeting outlives the arranging of it.

> **Status: working prototype.** Every check below is green and it has been
> driven end to end in a real browser. It has not yet been run on a real
> server: the Ansible deployment is reasoned and unvalidated, and
> [docs/PLAN.md](docs/PLAN.md) is honest about the rest.

## How it works

1. Someone starts a meeting and gets a link. No account.
2. Everyone opens the link and picks a name others will recognise —
   "Blue Falcon", not their own.
3. Each person clicks a preset — "weekdays 9–5" — then drags across the grid
   to fix the exceptions, or arrows around it and presses space. Only packed
   bits go over the wire.
4. The heatmap shows how many people are free in each slot, in each viewer's
   own timezone. It never shows *which* people. Every suggested time is
   labelled in everyone's local time, so nobody has to do the arithmetic.
5. **Once everybody has answered**, whoever started the meeting picks a time
   and everyone downloads an invitation. Not before: choosing while somebody is
   still deciding is how a meeting gets booked over the one person who could
   not make it. If somebody opened the link and went away, the host can go
   ahead without them — and nobody has to be named to do it.
6. **A chosen time is an answer, not an ending.** Plans change, so the host can
   move it, and anyone whose availability changes invalidates it automatically:
   the meeting simply starts saying "only 3 of 4 can make this". There is no
   separate acceptance to keep in step — the calendar invitation this exports
   is where people RSVP.
7. The host can call the whole thing off, which deletes it for everyone at
   once. Otherwise the room deletes itself a day after the meeting it
   scheduled, or after a month with nobody touching it. Every change resets
   that month — arranging a meeting between organisations really can take
   weeks, and a room that expired mid-negotiation would be worse than useless.
   Deploying the server does not count: rooms are snapshotted locally so a
   release does not take them with it.

## What the server never sees

Your email address, your name, or your calendar. There is no calendar
integration at all — no API, no file import — so there is no claim about
calendar data for you to have to trust.

Not even your timezone. Every instant it holds is UTC, and turning one into
"Tuesday at 10:00" happens in your browser against your own locale, so there is
nothing on the server that says where anybody is.

**No third party sees anything either.** The page makes no requests off the
origin: no analytics, no CDN, no font service. The two typefaces are served
from the same host, because loading them from Google would hand every visitor's
address to Google.

Everything it holds is a random room hash, a chosen alias per person, and the
stretches of time they said they were free. That is kept in RAM and mirrored to
one local file so a deploy or a reboot does not destroy your meeting — the only
thing written anywhere, deleted per room the moment the room ends.

Be clear about what that means: a room lives until a day after the meeting it
scheduled, or a month with nobody touching it. Choosing a time does not close
it — plans change, and the link has to still work when they do. So the honest
claim is **nothing outlives the arranging of the meeting**, not "nothing
outlives the day". Coordination genuinely takes weeks sometimes, and pretending
otherwise would just mean losing people's rooms.

**No other participant** learns who is free when. The server has to hold each
person's answer in order to add them up — it is not zero-knowledge and does not
claim to be — but a person's own row is never published, never logged, and
never outlives the room. Every watcher, the host included, sees how many people
are free in a slot and nothing more, which is the one thing When2meet and
Doodle will always tell you.

## Running it

Needs Erlang/OTP 27, rebar3 and Node 22. Nothing else — no services, no
containers, no disk.

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
boot, so the machine comes back on its own — `deploy/reboot.yml` is the drill
that proves it. The release bundles its own ERTS, so the server needs no Erlang
installed, but it must be built on the same Ubuntu; both CI and the playbook
check that.

`--tags reload` swaps changed modules into the running node without dropping a
socket, for a hotfix worth not interrupting anyone over.

A deploy stops the node and starts it again. The rooms survive because they are
snapshotted locally and read back before the listener opens; if that file is
gone, a room's address is derived from its host's token, so the host's browser
reopens it and everyone resubmits what their own browser held.

One machine, deliberately — a room lives in the memory of the process that
created it. [docs/OPERATIONS.md](docs/OPERATIONS.md) is the rest.

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
the browser. Staying that size is the design constraint, not a stage it is
passing through.

## Licence

[MIT](LICENSE), except the two typefaces in
`apps/fw_web/priv/static/fonts/`, which are Newsreader and Archivo under the
SIL Open Font License 1.1 — see
[the licence bundled with them](apps/fw_web/priv/static/fonts/OFL.txt).
