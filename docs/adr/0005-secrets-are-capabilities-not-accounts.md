# 0005. Secrets are capabilities: no accounts, no recovery

- Status: Accepted. The hash is now derived from the host token rather than
  independent of it — see [0008](0008-rooms-are-resumed-from-the-host-token.md) —
  and a timezone is kept per attendee, see
  [0009](0009-the-server-decides-the-browser-formats.md).
- Date: 2026-08-28

## Context

Three questions need answering and none of them may be answered with an
identity, because the product's premise is that the server never learns who
anyone is:

- Who may open this room?
- Who may replace this attendee's availability?
- Who may choose the final time?

Conventional answers — a login, an email link, a signed session — all require
knowing something about a person and keeping it.

## Decision

Each question is answered by holding a secret, and holding it is the entire
authorisation. All three are 128 bits from `crypto:strong_rand_bytes/1`,
base64url, 22 characters:

- **Room hash** — opens the room. It is the URL.
- **Host token** — permits picking a slot. Returned once by
  `POST /api/rooms` and never again; the browser keeps it in `localStorage`
  and it never appears in a URL.
- **Attendee id** — permits replacing that attendee's mask. Returned once as
  the reply to that client's own join.

The host token is compared with `crypto:hash_equals/2` after a length check,
because `hash_equals/2` raises rather than answering `false` on a length
mismatch.

Attendee ids are never published in a room snapshot. Watchers see an alias and
whether that person has set their availability, which is everything the grid
needs to draw, and an integration test asserts the id does not appear in the
JSON.

## Consequences

There is nothing to steal in bulk. No user table, no password hash, no session
store, no email address. The worst case for a leaked secret is one ephemeral
room, and it stops mattering within a day. (An IANA timezone per attendee was
added later by [0009](0009-the-server-decides-the-browser-formats.md); it is
the only thing here that describes a person at all.)

Enumeration is not a threat model, it is arithmetic: 128 bits of CSPRNG output
cannot be guessed, and there is no listing endpoint, no sequential id and no
timestamp in the identifier to narrow the space.

Losing a secret is unrecoverable, by construction. A host who clears their
browser storage cannot pick a time, and their room simply expires. There is no
reset flow because a reset flow needs an account to reset into. This is a real
usability cost and it is the honest consequence of the promise.

Anyone with the room link can join under any alias, and aliases are not unique.
That is the same trust model as a shared document link, and the room's
attendee cap plus its 24-hour life are what bound the damage.

Because the client identifies itself in the attendee list by matching its own
alias, two people choosing the same alias make the highlight ambiguous. It is
cosmetic — nothing about submitting or picking depends on it — and the fix, a
separate published non-secret seat id, is noted in `docs/PLAN.md` rather than
built.

## Alternatives considered

**A signed cookie or JWT per participant.** Standard, and it would give stable
identity across devices. Rejected: it means a signing key that outlives rooms,
a session concept, and a server that can tell two visits apart — all things the
design is trying not to have.

**Deriving a public id by hashing the secret one**, so a client can find itself
in the list without an extra field. Neat, but it needs `crypto.subtle` on the
client for an asynchronous digest to solve a cosmetic highlighting problem.

**Making the first connection the host implicitly.** No token to lose, but it
breaks the moment the host reloads, and it hands authority to whoever races to
the link first.
