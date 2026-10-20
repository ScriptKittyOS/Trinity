# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.Profile do
  @moduledoc """
  The N6 profile this tree implements, pinned: its version, its limits, and the closed table of
  refusal codes with the exit class of each (slice 138).

  N6 is a profile of deterministic CBOR (RFC 8949 section 4.2.1) and COSE_Sign1 (RFC 9052) for
  signed statements. The version implemented here is **v0, draft r3, provisional**: every rule may
  change until a frozen v1 is published with its vectors. `pin/0` names the draft and the SHA-384
  of its text, so a later draft is a visible change of pin, not a silent one.

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
    status: :provisional,
    draft_sha384:
      "54ab5e549259b87b18c51b4d1a3dbbbbb230b74ae562d5c2ef8ec43288c6c2dafc6376bff51ae205da6043bb9da7b7f2"
  }

  @limits %{depth: 16, items: 65_536, text: 65_536, size: 1_048_576}

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
    # The draft names signature failures per twin role (signature_invalid_kv, _kh); a
    # single-signer statement has no role yet (its section 12.1 item 1).
    signature_invalid: {1, :trinity},
    # Section 9.
    claim: {0, :draft},
    usage: {2, :draft},
    policy_stale_or_unknown_key: {5, :draft},
    # The runtime cannot run ML-DSA-87 (for example in FIPS mode on a provider that refuses it),
    # so the verifier cannot judge: no trust, never a pass and never a crash.
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
  @spec codes() :: %{code() => {0 | 1 | 2 | 5, :draft | :trinity}}
  def codes, do: @codes

  @doc "The exit class of a code. Raises on a code not in the table, which is a bug in the caller."
  @spec exit_of(code()) :: 0 | 1 | 2 | 5
  def exit_of(code), do: @codes |> Map.fetch!(code) |> elem(0)
end
