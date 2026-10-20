# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6 do
  @moduledoc """
  The N6 profile: deterministic CBOR and COSE_Sign1 for signed statements, with ML-DSA-87
  (slice 138) and, on the `commercial` profile, Ed25519 (slice 139).

  The rule it serves: every statement this tree constructs and signs is deterministic CBOR inside
  COSE_Sign1, and bytes someone else produced are hashed exactly as received, never re-encoded.

    * `Trinity.N6.CBOR`: the encoder and the strict decoder (rules E1 to E11);
    * `Trinity.N6.Body`: a statement body against its declared schema;
    * `Trinity.N6.Digest`: SHA-384 references to foreign bytes;
    * `Trinity.N6.COSE`: the header rules, the key thumbprint, signing and verifying;
    * `Trinity.N6.Carrier`: the single-signer carrier, one statement with its one Sign1;
    * `Trinity.N6.Profile`: the pinned draft, its limits, and every refusal code.

  This is a top-level boundary with no dependency on the rest of Trinity, as `Trinity.Keys` is,
  so it stays extractable: the compiler refuses a call from here into any other Trinity module.
  The profile is provisional (v0, draft r3, and the publisher's answers of 2026-10-19); see
  `Trinity.N6.Profile`. Nothing Trinity signed
  before this boundary existed is changed by it.
  """

  use Boundary, top_level?: true, deps: [], exports: [CBOR, Body, Digest, COSE, Carrier, Profile]
end
