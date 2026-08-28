# 0008. Rooms are resumed from the host token, not preserved on disk

- Status: Accepted, and now the layer beneath
  [0011](0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md) rather than the
  only answer: snapshots bring rooms back automatically, and resume covers a
  snapshot store that was off, empty or lost.
- Date: 2026-08-28

## Context

A room is one process's memory ([ADR 0001](0001-no-database-rooms-live-in-ram.md)),
so deploying destroys every room in progress. That was accepted early on and it
is not acceptable in use: a release in the middle of a working day takes away
everyone's answers with no warning and no way back.

The BEAM's own answer is hot code upgrade, and it does not apply here. Fly
deploys replace the machine with one built from a new image, so the VM that
held the rooms is gone before the new code runs. Relups solve a problem
container platforms have already taken away.

That leaves three shapes of answer:

1. Write the rooms down before shutdown and read them back on boot.
2. Hand them to a replacement node while both are running.
3. Have the people in the room hand back what they were holding.

## Decision

**A room's hash is the SHA-256 of its host token, truncated to 128 bits.**

`POST /api/rooms` accepts an optional `resume` field carrying a host token.
The server derives the hash, and if no room is live at that hash it creates one
there. Presenting the token is the proof of the right to that address, because
producing a token that hashes to somebody else's hash is a preimage attack.
Resuming a room that is still live changes nothing and returns the same answer,
so a client that is unsure whether the room is gone can simply ask.

Each browser keeps in `localStorage` what only it is holding: the host keeps
its token and the room's shape, and everyone keeps their own alias, timezone
and packed availability. On every connection a client resubmits what it
remembers; if the server answers `unknown_attendee`, the room was rebuilt
without it and it rejoins first. The socket retries forever with a ten-second
cap, so a guest reconnects on its own once the host has reopened the room.

Nothing is written to disk, and no room state is ever transmitted to storage.

## Consequences

A release stops being destructive in the common case. Everyone whose tab is
open is back in the room, with their availability, within about ten seconds of
the new node accepting connections, and nobody has to do anything.

The privacy claim survives intact. There is still nowhere for a room to be
read from — the pieces are distributed across the participants' own browsers
and each holds only what concerns them. That is a stronger property than the
snapshot alternative, not a weaker one.

**It is best-effort, and the gap is real.** A room comes back only if the
host's browser is open to reopen it. If the host has closed their tab, guests
keep knocking at an address nobody will recreate until the host returns. An
attendee who has closed their tab loses their availability regardless, because
their browser is the only thing that had it.

The host token grew to 256 bits and is now doing two jobs — the right to pick a
slot, and the right to the address. Losing it loses both. That concentration is
the price of having no server-side record, and it is why the token is stored
locally the moment a room is created rather than only shown once.

Room hashes are no longer independent random values. They are still 128 bits of
effectively uniform output, and the derivation is one-way, so sharing a link
still shares no authority. What changed is that two rooms can no longer collide
by chance without their tokens colliding first.

Recreating a room brings back the address, not the attendees. The room comes
back empty and refills as people reconnect, which means for a few seconds the
heatmap understates availability. Nobody can pick a slot in that window without
seeing it is wrong, so this is visible rather than dangerous.

## Alternatives considered

**Snapshot to a Fly volume on shutdown, restore on boot.** Reliable, complete,
and about eighty lines. It preserves rooms whether or not anyone's tab is open.
Rejected because it contradicts the product: the README says there is nowhere
for your data to go, and a file on a volume — even encrypted, even deleted on
read, even existing only for seconds — makes that a claim about our conduct
rather than about the system. If the best-effort gap above turns out to matter
more than the claim, this is the change to make, and it fits behind the
`fw_room_store` port without touching anything above it.

**Hand off to the replacement node over Erlang distribution.** The BEAM-native
answer, and it would preserve everything without disk. It needs two machines
running at once, private networking, node discovery, a cookie, and an ordering
guarantee that the new node is up before the old one drains. That is a
distributed system in a project whose case for existing is that it is one small
node with no dependencies.

**Accept the loss and warn clients.** The previous plan. Honest, and it leaves
the user with a browser full of work and nothing to do with it.
