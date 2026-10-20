# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.Profile do
  @moduledoc """
  The N6 profile this tree implements, pinned: its version, its limits, the closed table of
  refusal codes with the exit class of each (slice 138), and the schema numbers of its carriers
  (slice 139).

  N6 is a profile of deterministic CBOR (RFC 8949 section 4.2.1) and COSE_Sign1 (RFC 9052) for
  signed statements. The version implemented here is **v0, draft r3, provisional**: every rule may
  change until a frozen v1 is published with its vectors. `pin/0` names the draft and the SHA-384
  of its text, so a later draft is a visible change of pin, not a silent one.

  Slice 139 adds what the profile publisher's answers of 2026-10-19 add to r3 for a single signer,
  ahead of the draft that will carry them (v0.1): the single-signer carrier, and Ed25519 (-19) as the
  one classical algorithm on the `commercial` profile. Slice 140 adds the publisher's Decision of
  2026-10-20 (17:24Z, with its 17:27Z correction): ESP384 (-51) for FIPS-mode nodes, the schema
  numbers, `statement_id` as the link, one `typ` per kind, and ForeignRefs for text-keyed content.
  `pin/0` names both.

  ## Schema numbers

  Key 0 of a carrier is a number in the reserved range 0xFFFF0000 to 0xFFFFFFFF. r3 assigns two,
  still Open in it (its section 12.1 item 3); the publisher's Decision of 2026-10-20 assigns the
  single-signer carrier's, 0xFFFF0003, the value slice 139 had used as a placeholder.

  A statement kind's key 0 is `(block << 24) | (kind << 8) | version` (`statement_schema/3`): a
  block of 0x80 is the shared test block, accepted only in a verifier's declared test mode; blocks
  0x81 to 0x8F are provisional, one per publishing board, Trinity's 0x83; numbers below 0x80000000
  are N21's, none issued yet. Everything provisional is re-issued under N21 at v1.

  ## Codes

  Every refusal in `Trinity.N6` is one of the atoms in `codes/0`. Each carries its exit class
  (0 verified, 1 invalid, 2 usage, 5 no trust) and whether the draft defines it (`:draft`) or this
  tree does, where the draft leaves the code Open (`:trinity`). A `:trinity` code is provisional
  twice over: it changes when the draft settles that point.

  ## Limits

  The draft's numbers, Open in it (its section 12.1 item 2), counted as follows, which the draft
  also leaves Open (its VB2) and so is this tree's provisional reading:

    * **depth** is the number of arrays and maps around an item, the top-level container being 1:
      16 nested arrays are accepted, 17 are refused;
    * **items** counts every data item, map keys and the top-level item included;
    * **text** is the length of one text string in UTF-8 bytes;
    * **size** is the whole input in bytes. There is no separate limit on byte strings.

  Each is accepted at its value and refused one past it. Limits apply to bytes being decoded, not
  to bytes this tree constructs: a ToBeSigned may be larger than any body it carries.
  """

  @pin %{
    version: "n6/v0",
    draft: "r3",
    answers: [
      "the profile publisher's answers of 2026-10-19 (single-signer carrier, Ed25519 on commercial)",
      "the profile publisher's Decision of 2026-10-20 17:24Z and its 17:27Z correction (ESP384, " <>
        "schema numbers, statement_id, one typ per kind, ForeignRefs)"
    ],
    status: :provisional,
    draft_sha384:
      "54ab5e549259b87b18c51b4d1a3dbbbbb230b74ae562d5c2ef8ec43288c6c2dafc6376bff51ae205da6043bb9da7b7f2"
  }

  @limits %{depth: 16, items: 65_536, text: 65_536, size: 1_048_576}

  # carrier => {key 0 value, who assigned it}
  @schemas %{
    envelope: {0xFFFF0001, :draft},
    statement_id: {0xFFFF0002, :draft},
    single: {0xFFFF0003, :publisher}
  }

  @test_block 0x80
  @trinity_block 0x83

  # code => {exit class, who defines it}
  @codes %{
    # Section 2, the encoding rules.
    noncanonical: {1, :draft},
    indefinite_length: {1, :draft},
    key_not_uint: {1, :draft},
    duplicate_key: {1, :draft},
    int_out_of_range: {1, :draft},
    float_forbidden: {1, :draft},
    tag_forbidden: {1, :draft},
    simple_forbidden: {1, :draft},
    invalid_utf8: {1, :draft},
    not_nfc: {1, :draft},
    too_deep: {1, :draft},
    too_large: {1, :draft},
    too_many_items: {1, :draft},
    text_too_long: {1, :draft},
    trailing_bytes: {1, :draft},
    truncated: {1, :draft},
    # A head the draft's code table does not cover yet (its W6): additional information 28 to 30,
    # 31 on a major type that has no indefinite form, a lone break, 0xf8 below 32.
    not_well_formed: {1, :trinity},
    # A term the encoder cannot express in the subset (an atom, a bare binary, a tuple).
    value_not_n6: {1, :trinity},
    # Section 3, the body rules.
    schema_version_missing: {1, :draft},
    unknown_schema: {1, :draft},
    unknown_key: {1, :draft},
    schema_reserved: {1, :draft},
    # The publisher's Decision of 2026-10-20, point 2, checked between `schema_reserved` and
    # `unknown_schema` (its 17:27Z correction).
    test_schema_outside_test_mode: {1, :publisher},
    set_not_canonical: {1, :draft},
    body_not_map: {1, :trinity},
    required_key_missing: {1, :trinity},
    wrong_type: {1, :trinity},
    # Section 4, digests.
    digest_alg_not_permitted: {1, :draft},
    # The draft's own name for it (its W29), not yet in its code list.
    digest_length_mismatch: {1, :trinity},
    digest_malformed: {1, :trinity},
    # Section 5, COSE_Sign1.
    alg_not_permitted: {1, :draft},
    header_not_protected: {1, :draft},
    header_label_forbidden: {1, :draft},
    header_noncanonical: {1, :draft},
    content_type_forbidden: {1, :draft},
    countersignature_forbidden: {1, :draft},
    unprotected_forbidden: {1, :draft},
    kid_not_thumbprint: {1, :draft},
    typ_unexpected: {1, :draft},
    carrier_malformed: {1, :draft},
    wrong_carrier_for_typ: {1, :draft},
    # The draft names signature failures per twin role (signature_invalid_kv, _kh); a
    # single-signer statement has no role yet (its section 12.1 item 1).
    signature_invalid: {1, :trinity},
    # The publisher's Decision of 2026-10-20: an ESP384 signature that is not the 96-byte r || s
    # (point 1), a key-0 value whose `typ` is another kind's (point 3), a full-payload
    # single-signer body without key 1 (point 3).
    signature_encoding: {1, :publisher},
    typ_schema_mismatch: {1, :publisher},
    issuer_missing: {1, :publisher},
    # A registered key that is not what its algorithm needs: for ESP384, a compressed point, another
    # curve, or a point not on P-384. The Decision asks for the check and names no code.
    key_invalid: {1, :trinity},
    # Point 4: the bytes a ForeignRef names. Missing bytes are a finding (no trust where the content
    # must be judged); bytes that do not match are invalid for the attachment, never for the signed
    # statement.
    foreign_bytes_missing: {5, :publisher},
    foreign_digest_mismatch: {1, :publisher},
    # Section 9.
    claim: {0, :draft},
    usage: {2, :draft},
    policy_stale_or_unknown_key: {5, :draft},
    # The runtime cannot run the header's algorithm (ML-DSA-87, Ed25519 or ESP384; FIPS mode refuses
    # Ed25519, and Red Hat's provider ML-DSA-87), so the verifier cannot judge: no trust, never a pass
    # and never a crash.
    alg_unavailable: {5, :trinity}
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

  @doc "Every code, with its exit class and whether the draft defines it."
  @spec codes() :: %{code() => {0 | 1 | 2 | 5, :draft | :publisher | :trinity}}
  def codes, do: @codes

  @doc """
  The reserved-range schema numbers of the carriers, each with who assigned it: `:draft` (r3, still
  Open there) or `:publisher` (the publisher's answers, ahead of the draft that will carry them).
  """
  @spec schemas() :: %{atom() => {non_neg_integer(), :draft | :publisher}}
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
