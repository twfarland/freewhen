# Developing

Everything runs on a laptop with no services, no containers and no disk. Two
terminals is the whole loop.

## The loop

```sh
cd web && npm ci && npm run watch     # terminal 1: rebuilds app.js on save
rebar3 shell                          # terminal 2: http://localhost:8080
```

`rebar3 shell` boots `fw_web` and everything under it with `config/sys.config`.
Reload the browser after a client change; esbuild has already written the
bundle.

For a server change, recompile **in the shell** rather than restarting it:

```erlang
1> r3:do(compile).
```

That rebuilds and swaps the changed modules into the running node, which is the
same mechanism `--tags reload` uses in production and has the same limit: it does not migrate `gen_server` state. Change the shape of
`fw_room_server`'s record and you want `Ctrl-G q` and a fresh shell.

Rooms live in the shell's memory, so quitting discards them. That is the
default and it is deliberate — development and CI never touch a disk.

## Validating it by hand

Two browser profiles are two people. **An incognito window has its own
localStorage**, and localStorage is the only place this client keeps anything —
the host token, the alias, the attendee id, the availability — so an incognito
window is a genuinely separate participant, not the same one twice. Nothing is
shared between them but the room link.

Start the server, open `http://localhost:8080`, and:

1. **Create a room** in the normal window. You are the host: the token lands in
   this profile's localStorage and nowhere else.
2. **Copy the link** and paste it into an incognito window. It is
   `http://localhost:8080/m/#<hash>` — the hash is in the *fragment*, which
   browsers never send to the server.
3. **Join under different names** in each. The incognito window has no host
   token, so it gets no "choose a time" buttons; that is the capability model
   working, not a bug.
4. **Paint in one and watch the other.** The heatmap updates live in both.
   Check the other window shows *counts* and never which person — that is the
   whole product.
5. **Reload either window.** It should come straight back into the room with
   its availability intact and no join form. This is the bug that shipped
   before there were client tests, so it is worth checking every time.
6. **Restart `rebar3 shell`.** Both windows say "Reconnecting…", the host's
   browser reopens the room at the same address, and everyone resubmits what
   they were holding. Rooms come back because the people in them still have the
   pieces; on the server that is snapshots, and in development snapshots are
   off, so this exercises the resume-from-host-token path.
7. **Pick a time** in the host window and download the invitation.

Worth checking while you are there:

- **The keyboard.** Tab to the grid — it is one tab stop — then arrow around,
  space to toggle, shift+arrow to paint a run. Home and End are the ends of a
  day. Everything you can do by dragging you should be able to do here.
- **A clock change.** Create a room whose week contains the last Sunday in
  March or October and check the columns are 23 and 25 hours long, and that
  the weekday preset lands on 09:00 local on both sides of it.
- **A duplicate name.** Joining under a name already in the room is refused by
  the client. It is not yet refused by the server — see `docs/PLAN.md`.

### Two things that look like bugs and are not

**`429` on creating rooms.** The token bucket allows about one room per ten
seconds from one address, and in development both windows are 127.0.0.1. Six
creates in a row gives one `201` and five `429`s. That is the limiter working.

**Rooms vanish when you stop the shell.** Snapshots are off unless
`FW_SNAPSHOT_FILE` is set, so a room only survives a restart if a host's tab is
still open to resume it. Set the variable, below, to exercise the other path.

## Running it the way the server does

Snapshots are off unless `FW_SNAPSHOT_FILE` points somewhere, so this is how to
exercise the durability path locally:

```sh
FW_SNAPSHOT_FILE=/tmp/freewhen.dets rebar3 shell
```

Create a room, quit the shell, start it again, and watch for
`freewhen restored N rooms` in the boot log.

To run the actual artefact rather than a shell:

```sh
cd web && npm run build && cd ..
rebar3 as prod release
_build/prod/rel/freewhen/bin/freewhen console
```

That release is only runnable on the platform that built it — `include_erts`
means it carries its own runtime, linked against the local libc. On Windows
`rebar3 as prod tar` produces `.cmd` scripts and no POSIX ones, so a deployable
tarball has to be built on Ubuntu 24.04. CI does this.

## Checks

```sh
rebar3 do compile, eunit, ct, xref, dialyzer
cd web && npm run check && npm test
```

`npm test` is `node --test` run straight over the TypeScript, with no framework
and no build step.
Tests live beside their modules as `*.test.ts`. Anything that touches a clock
sets `process.env.TZ` at the top of the file, which only works because nothing
in the client constructs a `Date` at import time — keep it that way.

`eunit` is the pure domain and runs in about two seconds with no setup — if a
test in `fw_core` needs setup, something has leaked into the domain. `ct`
starts a real cowboy on a real socket and talks to it with `gun`.

Warnings are errors, every export needs a `-spec`, and dialyzer and xref must
be clean before anything is committed.

## The guardrails

A `PostToolUse` hook (`.claude/hooks/check_erl.escript`) rejects an edit to a
module that breaks a layer rule or the size limits — 200 lines per module, 30
per function. Hitting a limit is a design signal, not a formatting problem.

`CLAUDE.md` is the short version of the rules and
[ARCHITECTURE.md](ARCHITECTURE.md) is the long one, including a **Decisions**
section that says why each piece is shaped the way it is. Change a decision
there in the same commit as the code.

## Environment

Nothing is required. All four variables have defaults that are right for a
laptop:

| variable | default | in development |
|---|---|---|
| `PORT` | 8080 | leave it |
| `FW_BIND` | every interface | leave it, unless testing the proxy setup |
| `FW_ALLOWED_ORIGINS` | accept any | leave it; production sets the real origin |
| `FW_SNAPSHOT_FILE` | unset, so no disk | set it to exercise durability |
