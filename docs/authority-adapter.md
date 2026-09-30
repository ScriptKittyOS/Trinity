<!--
SPDX-FileCopyrightText: Sudo Apt Holdings LLC
SPDX-License-Identifier: Apache-2.0
-->
# Writing an authority adapter

How to make an external authority layer the one that decides for this node.

**Every claim here is a path in this repository, or says NOT IN TREE.** A sentence you cannot follow
to a file is a sentence you should not trust.

## The split

> Anything may propose. The authority in force authorizes. After an allow, this node's Elixir runs
> the tool.

The adapter **decides**. It does not run the tool, and it does not change what it was asked about.

## One module, chosen once, at boot

`TRINITY_AUTHORITY` names one module. It is read once, by `Trinity.Authority.Selection`
(`lib/trinity/authority/selection.ex`), as the first child of the application after the data
directory lock, and the selection is kept in `:persistent_term`. No runtime path changes it.

- unset, `""`, or `local` selects `Trinity.Authority.Local`.
- any other value is an Elixir module name, with or without the `Elixir.` prefix.
- the module must be **loaded** and must export every callback, or the boot stops and the refusal
  names which: `{:not_loaded, name}` or `{:missing_callback, module, {name, arity}}`.
- a name that is not an existing atom is reported as not loaded, and no atom is created from the
  environment's text.

Selection is **synchronous**: `Selection.start/0` completes before any later child starts, so there
is no window in which the node is running with the selection still being made. Before that,
`Trinity.Authority.impl/0` (`lib/trinity/authority.ex`) answers `Local` under `:default` and
**raises** under `:regulated`, because a brief fallback to the local authority is still a fallback.

`Trinity.Authority.Local` (`lib/trinity/authority/local.ex`) is **the only implementation in this
tree**. Everything else is NOT IN TREE: this repository holds no client, no envelope, no schema and
no transport for any particular authority layer, and a test asserts that under `local` no adapter
module is loaded (`test/trinity/authority/selection_test.exs`).

## The regulated profile refuses the local authority

Under `TRINITY_PROFILE=regulated` the node refuses to boot on `Trinity.Authority.Local`:

- the rule is `Trinity.Profile.check_authority/2` in `lib/trinity/profile.ex`, which answers
  `{:error, :regulated_refuses_local_authority}`.
- it is asked at boot, before any child exists, by `verify_regulated_configuration!/0` in
  `lib/trinity/application.ex`.
- an unset `TRINITY_AUTHORITY` resolves to `Local` and is therefore refused too.
- a name that cannot be resolved is refused as `{:regulated_authority_unselectable, reason}`,
  carrying the selection's own reason, and `check_authority/2` is total, so a caller that loses the
  reason still gets `{:regulated_authority_unresolved, value}` rather than a crash.

The refusals are tested in `test/trinity/profile_test.exs`, and at an actual boot, in spawned OS
processes, in `test/trinity/regulated_boot_node_test.exs`.

## The callbacks

Four are required. `Trinity.Authority.callbacks/0` is the list the selection checks against, in
`lib/trinity/authority.ex`.

| callback | answer | what it is for |
| --- | --- | --- |
| `stage/2` | `{:ok, Staged.t()}` or `{:error, term()}` | record that an effect is about to happen |
| `decide/3` | `{:ok, :allow \| :deny, basis}` or `{:error, term()}` | **the decision**, with a basis saying why |
| `execute/3` | `{:error, :not_the_effect_path}` | reserved; see below |
| `receipt/2` | `{:ok, term()}` or `{:error, term()}` | record a receipt of a kind |

And one optional:

| callback | answer | what it is for |
| --- | --- | --- |
| `forward_receipt/2` | `:ok` or `{:error, term()}` | acknowledge a queued receipt envelope |

### `decide/3` returns allow or deny, and never falls back

`:allow` or `:deny`. An adapter that cannot reach its far side returns `{:error, reason}` or
`:deny`; it must **not** decide locally, and it must not answer as though the local gate had
decided. The membrane treats `{:ok, :deny, basis}` as a denial with a receipt, and `{:error, _}` as
a denial with a receipt. Both are safe. A fallback to `Local` is the one answer that is not.

### `execute/3` must not run a tool

It is **not** the place the effect happens, and nothing on the effect path calls it. After a
`decide/3` allow and after the admission receipt is in the chain, `Trinity.Effects.run_tool/2`
(`lib/trinity/effects.ex`) calls the tool's own `execute/2`, in this VM.

It stays in the behaviour so that an adapter written against the older contract, where returning a
result from it was how the effect happened, is not silently accepted. Answer
`{:error, :not_the_effect_path}`, which is what `Trinity.Authority.Local` answers.

### `stage/2` may not change the subject

Set `staged_at` and `basis`. Nothing else. Every other field of the `Trinity.Authority.Staged`
(`lib/trinity/authority/staged.ex`) you return must be the one you were given.

After `stage/2` the membrane re-derives the fingerprint over the arguments you returned and compares
it to the one the gate bound, not to the one your struct now carries, so rewriting `args` and
`fingerprint` to agree with each other does not pass. It then compares every remaining field,
because the fingerprint covers the session, the tool name, the arguments and the working directory,
and covers `module` not at all: an adapter could otherwise leave every fingerprinted field alone and
still change which code runs.

Both refusals are tested against adapters that actually attempt them, in
`test/trinity/effects/membrane_test.exs` with `Trinity.TestAuthority.MutatesArgs` and
`Trinity.TestAuthority.SwapsModule` (`test/support/authority/adapters.ex`), alongside a control
adapter that changes nothing and whose effect runs.

## Receipts: Trinity writes them, the adapter acknowledges them

Trinity signs and appends its own receipts, locally, around the effect: an `admit` before the tool
runs and a `done` after it, or a `denied` instead. That is `Trinity.Effects` and
`Trinity.Receipts`. **The adapter does not write Trinity's receipts.**

What an adapter may do is receive them. `forward_receipt/2` is offered the exported envelope
**byte for byte, exactly as it was signed**. An implementation must not re-sign it, rebuild it or
alter a leaf: the point is that a verifier checks the signature over those bytes offline, which is
what lets a queue wrap, delay and re-deliver an envelope without the far side knowing a queue
exists. `:ok` acknowledges; any error leaves the entry pending to be offered again, oldest first.
An implementation that does not export it is one this machine never forwards to, and the queue for
its scopes simply does not drain. See `lib/trinity/receipts/queue.ex` and
`test/trinity/receipts/queue_test.exs`.

## `act_hash` is opaque

An authority layer may bind its decision to an act identifier. **Trinity treats it as opaque.** It
does not parse it, does not recompute it and does not depend on its shape; it carries it and stores
it beside the decision.

Where an adapter records one, it should record the algorithm beside it, as `act_hash` and
`act_hash_alg`, so a reader is never guessing which construction produced the digest. The value
this contract expects is `sha256+rfc8785-v1`: SHA-256 over the [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785)
canonical JSON form. Trinity already uses RFC 8785 for its own approval fingerprints and holds a
conformance vector for it (`test/support/rfc8785_input.json`, `test/support/rfc8785_expected.txt`),
so the canonicalisation is not a new dependency here.

**`act_hash` is NOT IN TREE.** No field, column or function of that name exists in this repository.
It is named here so an adapter and this node agree on the word, not because Trinity reads it.

## Packaging an adapter

The adapter lives **outside this repository**, and the release that contains both is built outside
it too. This tree builds a Trinity that can be pointed at one; it does not build, vendor or depend
on any. A wrapper release adds the adapter module to the code path and sets `TRINITY_AUTHORITY`.
Anything more than that is NOT IN TREE.

## Checklist

- [ ] the module is loaded in the release, and `TRINITY_AUTHORITY` names it
- [ ] `stage/2`, `decide/3`, `execute/3`, `receipt/2` are exported
- [ ] `stage/2` changes nothing but `staged_at` and `basis`
- [ ] `decide/3` answers `:allow` or `:deny`, and never falls back to a local decision
- [ ] `execute/3` runs no tool
- [ ] `forward_receipt/2` acknowledges bytes it did not alter, or is absent on purpose
- [ ] under `TRINITY_PROFILE=regulated`, the node boots, which means it did not select `Local`
