<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Authorization boundary

What sits inside the accredited boundary when Trinity runs, what sits outside it, and the one thing
about the standalone configuration an assessor has to understand before anything else in this pack
is useful.

## The boxes

```
                        ACCREDITED BOUNDARY (yours)
   +--------------------------------------------------------------+
   |                                                              |
   |   [ Trinity process ]            [ Receipts store ]          |
   |   BEAM/OTP application            hash-linked signed chain    |
   |   permission gate, effect         own SQLite file, own        |
   |   membrane, session loop          connection pool             |
   |                                                              |
   |   [ Customer files ]                                          |
   |   the filesystem roots you                                    |
   |   grant, and nothing else                                     |
   |                                                              |
   +--------------------------------------------------------------+
               |                                  |
               | prompt + completion              | OIDC / OAuth 2.1
               v                                  v
        [ Model endpoint ]                   [ Customer IdP ]
        OUTSIDE the boundary                 OUTSIDE the boundary
```

| Box | Inside the boundary? | Path |
|---|---|---|
| Trinity process | Yes. Runs on your host, under your accounts | `lib/trinity/application.ex` |
| Receipts store | Yes. Its own database file, separate from the primary | `lib/trinity/repo/receipts.ex`, `lib/trinity/paths.ex` |
| Customer files | Yes. Only the roots you grant | `lib/trinity/tools/fs/` |
| Model endpoint | **No.** Whatever you point it at, wherever it runs | `config/llm.exs:14` (the model list) |
| Customer IdP | **No.** Yours, and Trinity is a resource server to it | `lib/trinity/mcp/auth/`, `config/runtime.exs:100` |

Trinity holds a single-instance lock on the data directory so two processes cannot share one store:
`lib/trinity/data_dir/lock.ex`.

## Standalone: judge, actor and scribe

In the default configuration (`TRINITY_AUTHORITY` unset, or `local`) Trinity decides whether an
effect may happen, performs it, and writes the record of having done so. All three roles are the
same process.

- The decision is `lib/trinity/permissions/`, through `lib/trinity/authority/local.ex`.
- The effect crosses one boundary, `lib/trinity/effects.ex`, which re-derives the fingerprint from
  the arguments actually passed before admitting the call.
- The record is `lib/trinity/receipts/chain_writer.ex`, signed before the row is written.

**What that is worth.** It is strong evidence to a reader who accepts that the host was not
compromised: the chain is hash-linked and signed, the effect population is closed and published,
and the verifier runs without the application. It proves the software did what the record says.

**What it is not.** There is no separation of duties. A party who does not already trust the host
has only the host's word for it, because the same process made the decision and wrote the record of
the decision. `docs/10-assurance-case.md` states this, and criterion C6 there records that a signing
key in a file proves the records were not altered by anything lacking read access to that file, and
proves nothing about custody of the key.

**A signed receipt with an untrusted clock is weaker evidence than one with a trusted clock**, and
Trinity's clock is the host's own reading: `lib/trinity/receipts/clock.ex`. A deployment that needs
the time itself to be trustworthy supplies a trusted time source. `docs/09-standards-register.md`
carries that as a real-world dependency rather than a property of this tree.

## Regulated use requires an external authority

For a boundary where the decision must not be the machine's to make, Trinity supports pointing
`TRINITY_AUTHORITY` at an adapter that lives outside this repository. When one is in force, Trinity
keeps **no executor** for the effects that adapter governs, and that absence is asserted by a census
over the tree rather than by intent (`lib/trinity/authority.ex`, and the census recorded in slice
027's record).

The adapter itself is **NOT IN TREE**. ADR-0008 (`docs/adr/0008-authority-is-an-adapter.md`) states
that no slice in this repository builds one and that it is downstream work in a downstream
repository. An assessor evaluating a regulated deployment is evaluating that adapter as well as
this software, and this pack says nothing about it.

## What crosses the boundary, and when

| Crossing | Direction | Gate | Path |
|---|---|---|---|
| Prompt and completion | Out, then in | Every turn | `lib/trinity/sessions/prompt.ex:45` |
| Tool effects on files | Inside only | Permission gate, then membrane | `lib/trinity/effects.ex` |
| Web fetch and search | Out | Permission gate | `lib/trinity/tools/` |
| MCP server requests | In | OAuth 2.1 resource server | `lib/trinity/mcp/auth.ex` |
| Receipt forwarding | Out, if configured | Optional authority callback | `lib/trinity/receipts/forwarder.ex` |

A witness or transparency service that would let a third party detect backdated forgery without
trusting the host is **NOT IN TREE**.
