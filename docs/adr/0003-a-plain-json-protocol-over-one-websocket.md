# 0003. A plain JSON protocol over one websocket, and a plain TypeScript client

- Status: Accepted
- Date: 2026-08-28

## Context

A room's authoritative state lives in one `gen_server` on one node. Every
participant's browser needs a live view of it: the availability heatmap changes
whenever anyone submits a mask, and every connected client must see the change
without polling.

[nonchalant](https://github.com/twfarland/nonchalant) — a library written by
this project's author — defines a language-independent wire protocol for
exactly this shape of problem: eight JSON operations carrying structural state
patches, specified in a document and shipped with conformance vectors so that a
non-JavaScript host can certify against the reference implementation.

We built that host. It worked: an Erlang implementation of the codec, RFC 6901
pointers, `reconcile`, patch application and the session state machine passed
all 28 patch vectors and both scripted session vectors on the first run. It was
around 600 lines of source plus tests, in eight modules.

Then we looked at the whole system next to it. FreeWhen's entire state tree is
one room: a grid, a list of at most a few dozen attendees, an array of slot
counts, and a picked slot. A full snapshot is about a kilobyte of JSON.

## Decision

Rooms are watched over a plain websocket at `/ws/rooms/:hash`, carrying eight
JSON message types with no correlation ids and no patches. Every change sends
the whole room.

    client -> server                      server -> client
    {type: join,   alias}                 {type: state,  room}
    {type: submit, attendeeId, busy}      {type: joined, attendeeId}
    {type: leave,  attendeeId}            {type: error,  reason}
    {type: pick,   hostToken, slot}       {type: closed, reason}

The client is plain TypeScript with no framework, bundled by esbuild into one
file. `fw_room_json` is the only module on either side that knows the shape.

## Consequences

The protocol layer disappears. Eight modules and their tests are replaced by
one 120-line module that projects a room to JSON and decodes four messages, and
a websocket handler that is mostly a `case`. There is no diff to be wrong, no
pointer escaping to get wrong, no session state machine to reason about, and no
external specification to stay conformant with.

We send more bytes. A snapshot is roughly a kilobyte and a busy room might
produce one every few seconds per watcher, against the tens of bytes a patch
would have cost. For a room with a handful of participants that is nothing, and
it is the trade we are deliberately making: bandwidth is cheap here and
complexity is not.

Reconnect becomes the client's problem, and it is a small one — reopen the
socket and the first message is the whole room. We lose the property that a
reconnect updates only the bindings whose data changed, which matters when a
framework is driving fine-grained DOM updates and does not matter when the
client redraws a grid.

We keep a capability we would rather not have needed: because the whole state
is resent, a client cannot tell *what* changed without comparing. Nothing in
the UI needs to, so this costs nothing today.

The room hash now appears in a URL path — the websocket upgrade — where before
it would have travelled inside a `lookup` frame. Frames are not logged by
proxies and paths sometimes are. Nothing in this application logs the path, and
the page URL keeps the hash in the fragment so it is never sent when loading
the page, but this is a genuine reduction in defence and is recorded here as
one.

## Alternatives considered

**The nonchalant wire protocol, with its TypeScript client.** Genuinely better
on its merits for a larger state tree: patches keep updates proportional to the
change, reconnect delivers a full snapshot that diffs against what the client
kept, and the client half is already written and tested. It also had real value
beyond FreeWhen — a second, independent host is the experiment that proves the
specification is complete, and this is a low-stakes place to run it.

It lost on proportion. The protocol is designed for state trees deep enough
that a diff pays for itself, and this one is a kilobyte. Carrying a
general-purpose protocol implementation as the largest component of a system
whose entire premise is that it is small and holds nothing was the wrong shape,
however good the protocol is. The work is not wasted — it demonstrated the
specification is implementable from the documents alone — but it does not
belong in this repository.

**React with TanStack Query.** TanStack Query caches and invalidates HTTP
requests; the server here pushes state down a socket and there is nothing to
cache or invalidate. It would be a large dependency doing none of its job.

**Server-rendered HTML over the socket, LiveView style.** Rejected on the
product's own terms. Zero-trust means the server must never learn which slots a
named person is free, and a server that renders the grid is a server that knows
what the grid says. Anonymous aggregate counts are the most the server is
allowed to hold, which makes a data protocol the only honest option.
