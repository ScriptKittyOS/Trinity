# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.Profile do
  @moduledoc """
  The N6 profile this tree implements, pinned: its version, its limits, the closed table of
  refusal codes with the exit class of each (slice 138), and the schema numbers of its carriers
  (slice 139).

  N6 is a profile of deterministic CBOR (RFC 8949 section 4.2.1) and COSE_Sign1 (RFC 9052) for
  signed statements. The version implemented here is **v0.1, draft v0.1-r7, provisional** (slice
  142; slices 138 to 140 implemented v0 draft r3 and the publisher's answers that followed it):
  every rule may change until a frozen v1 is published with its vectors. `pin/0` names the draft
  and the digest of its posted source, so a later draft is a visible change of pin, not a silent
  one.

  ## Schema numbers

  Key 0 of a carrier is a number in the reserved range 0xFFFF0000 to 0xFFFFFFFF: 0xFFFF0001 the
  twin envelope, 0xFFFF0002 the `statement_id` preimage, 0xFFFF0003 the single-signer carrier (r7
  section 12.1 item 3, closed).

  A statement kind's key 0 is `(block << 24) | (kind << 8) | version` (`statement_schema/3`): a
  block of 0x80 is the shared test block, accepted only in a verifier's declared test mode; blocks
  0x81 to 0x8F are provisional, one per publishing party, Trinity's 0x83; numbers below 0x80000000
  are the registry's, none issued yet. Everything provisional is re-issued at v1.

  ## Codes

  Every refusal in `Trinity.N6` is one of the atoms in `codes/0`, which is r7's closed registry
  (its section 9.4) restricted to what this tree can emit, plus the codes marked `:trinity`. Each
  carries its exit class (0 verified, 1 invalid, 2 usage, 5 no trust) and the steps that emit it.

  ## Limits

  r7 section 2.1, each checked where its step says:

    * **depth** is the number of arrays and maps on the path to an item, counting the item itself
      if it is one; the top-level container is 1: 16 nested arrays are accepted, 17 are refused;
    * **items** counts every data item: the top-level item, and each container's declared contents
      at its head (n for an array, 2n for a map), before they are read;
    * **text** is the length of one text string in UTF-8 bytes;
    * **size** is the whole input in bytes. There is no separate limit on byte strings.

  Limits apply to bytes being decoded, not to bytes this tree constructs: a ToBeSigned may be
  larger than any body it carries.
  """

  @pin %{
    version: "n6/v0.1",
    draft: "v0.1-r7",
    answers: [
      "the profile publisher's Decisions of 2026-10-20 and 2026-10-21 that draft v0.1-r7 carries",
      "the publisher's Ed25519 verification rule of 2026-10-21 09:12Z (r7 section 5.3, decided)"
    ],
    status: :provisional,
    # The SHA-256 the publisher posted with the draft's source file.
    draft_sha256: "0b0d41382f5221fee48ccb16bce3f33e47f4cd59dba4f7b0bf8d9f5c1fcd1a25"
  }

  @limits %{depth: 16, items: 65_536, text: 65_536, size: 1_048_576}

  # carrier => {key 0 value, who assigned it}
  @schemas %{
    envelope: {0xFFFF0001, :draft},
    statement_id: {0xFFFF0002, :draft},
    single: {0xFFFF0003, :draft}
  }

  @test_block 0x80
  @trinity_block 0x83

  # code => {exit class, who defines it, where it is emitted}. The steps are draft v0.1-r7's: D0 to
  # D18 (section 2.2, the decoder), B1 to B8 (section 3.6, the body), H1 to H4 (section 5.6, the
  # protected header), K1 to K3 (section 5.2, a key), and the verifier steps section 9.4 names.
  @codes %{
    # Section 2, the encoding rules.
    too_large: {1, :draft, [:d0]},
    truncated: {1, :draft, [:d1, :d4, :d12, :d13]},
    not_well_formed: {1, :draft, [:d2, :d5]},
    indefinite_length: {1, :draft, [:d3]},
    key_not_uint: {1, :draft, [:d6, :d9, :b3]},
    tag_forbidden: {1, :draft, [:d7]},
    float_forbidden: {1, :draft, [:d7]},
    simple_forbidden: {1, :draft, [:d7]},
    noncanonical: {1, :draft, [:d8, :d10, :d18]},
    duplicate_key: {1, :draft, [:d10]},
    int_out_of_range: {1, :draft, [:d11]},
    too_deep: {1, :draft, [:d12]},
    too_many_items: {1, :draft, [:d12]},
    text_too_long: {1, :draft, [:d14]},
    invalid_utf8: {1, :draft, [:d15]},
    text_unassigned: {1, :draft, [:d16]},
    text_format_control: {1, :draft, [:d16]},
    not_nfc: {1, :draft, [:d16]},
    nfc_maybe: {1, :draft, [:d16]},
    trailing_bytes: {1, :draft, [:d17]},
    # A term the encoder cannot express in the subset (an atom, a bare binary, a tuple). The encoder
    # refuses it; no verifier emits it, so it is never a verdict.
    value_not_n6: {1, :trinity, [:encoder]},
    # Section 3, the body rules.
    body_not_map: {1, :draft, [:b1]},
    schema_version_missing: {1, :draft, [:b2]},
    schema_reserved: {1, :draft, [:b4]},
    test_schema_outside_test_mode: {1, :draft, [:b5]},
    unknown_schema: {1, :draft, [:b6]},
    typ_schema_mismatch: {1, :draft, [:b7]},
    issuer_missing: {1, :draft, [:b8]},
    field_missing: {1, :draft, [:b8]},
    unknown_key: {1, :draft, [:b8]},
    field_type_mismatch: {1, :draft, [:b8]},
    value_out_of_range: {1, :draft, [:b8]},
    text_grammar_mismatch: {1, :draft, [:b8]},
    set_not_canonical: {1, :draft, [:b8]},
    # Section 4, digests.
    digest_alg_not_permitted: {1, :draft, [:b8, :h4]},
    digest_length_mismatch: {1, :draft, [:b8, :carrier]},
    # Sections 5.2 and 5.6, keys and the protected header.
    header_noncanonical: {1, :draft, [:h1, :h2]},
    header_label_forbidden: {1, :draft, [:h1, :h4]},
    header_missing: {1, :draft, [:h3, :h4]},
    typ_unexpected: {1, :draft, [:h3]},
    wrong_carrier_for_typ: {1, :draft, [:h3, :carrier]},
    content_type_forbidden: {1, :draft, [:h4]},
    header_value_invalid: {1, :draft, [:h4]},
    alg_not_permitted: {1, :draft, [:h4, :k1]},
    key_invalid: {1, :draft, [:k2]},
    kid_not_thumbprint: {1, :draft, [:k3]},
    # Section 5, the carrier and the signature.
    carrier_malformed: {1, :draft, [:carrier]},
    header_not_protected: {1, :draft, [:carrier]},
    unprotected_forbidden: {1, :draft, [:carrier]},
    countersignature_forbidden: {1, :draft, [:carrier]},
    signature_encoding: {1, :draft, [:signature]},
    signature_invalid: {1, :draft, [:signature]},
    # Section 4.1: the bytes a ForeignRef names. Missing bytes are a finding (no trust where the
    # content must be judged); bytes that do not match are invalid for the attachment, never for
    # the signed statement.
    foreign_bytes_missing: {5, :draft, [:attachment]},
    foreign_digest_mismatch: {1, :draft, [:attachment]},
    # Section 9.
    claim: {0, :draft, [:verdict]},
    usage: {2, :draft, [:invocation]},
    policy_stale_or_unknown_key: {5, :draft, [:key_resolution]},
    # The runtime cannot run the header's algorithm (ML-DSA-87, Ed25519 or ESP384; FIPS mode refuses
    # Ed25519, and Red Hat's provider ML-DSA-87), so the verifier cannot judge: no trust, never a pass
    # and never a crash. Not in draft v0.1-r7's registry; asked of the publisher on 2026-10-21.
    alg_unavailable: {5, :trinity, [:signature]}
  }

  @typedoc "A refusal code, or `:claim` for a full verdict."
  @type code :: atom()

  @doc "The draft this tree implements and the SHA-384 of its posted text."
  @spec pin() :: map()
  def pin, do: @pin

  @doc "The four limits, counted as the moduledoc says."
  @spec limits() :: %{
          depth: pos_integer(),
          items: pos_integer(),
          text: pos_integer(),
          size: pos_integer()
        }
  def limits, do: @limits

  @doc """
  Every code, with its exit class, whether the draft defines it (`:draft`) or this tree does
  (`:trinity`), and the steps that emit it.
  """
  @spec codes() :: %{code() => {0 | 1 | 2 | 5, :draft | :trinity, [atom()]}}
  def codes, do: @codes

  @doc """
  The reserved-range schema numbers of the carriers, each with who assigned it (all `:draft` since
  v0.1-r7 closed them).
  """
  @spec schemas() :: %{atom() => {non_neg_integer(), :draft}}
  def schemas, do: @schemas

  @doc "The key 0 value of a carrier."
  @spec schema(:envelope | :statement_id | :single) :: non_neg_integer()
  def schema(carrier), do: @schemas |> Map.fetch!(carrier) |> elem(0)

  @doc """
  A statement kind's key 0: `(block << 24) | (kind << 8) | version`, with `kind` 1 to 65,535 and
  `version` 1 to 255.
  """
  @spec statement_schema(0..0x8F, 1..65_535, 1..255) :: non_neg_integer()
  def statement_schema(block, kind, version)
      when block in 0..0x8F and kind in 1..65_535 and version in 1..255,
      do: Bitwise.bsl(block, 24) + Bitwise.bsl(kind, 8) + version

  @doc "Trinity's provisional block, 0x83."
  @spec trinity_block() :: 0x83
  def trinity_block, do: @trinity_block

  @doc "Whether a key-0 value is in the shared test block, 0x80."
  @spec test_schema?(non_neg_integer()) :: boolean()
  def test_schema?(n) when is_integer(n), do: Bitwise.bsr(n, 24) == @test_block

  @doc "The exit class of a code. Raises on a code not in the table, which is a bug in the caller."
  @spec exit_of(code()) :: 0 | 1 | 2 | 5
  def exit_of(code), do: @codes |> Map.fetch!(code) |> elem(0)
end
