# N6 vectors (Trinity candidate set, provisional)

Written by `scripts/n6_vectors.exs`; do not edit by hand. The layout follows section 10 of the N6
profile v0, draft r3, which is provisional: every rule may change until v1 is frozen with the
profile's own vectors. These are candidate input, not the published set.

* Pin: `VERSION`, plus `SHA384SUMS`, which `sha384sum -c SHA384SUMS` checks from this directory
  (lines `<lowercase hex>  <path>`, sorted by path, LF; every file but itself).
* `*.desc.json`: the value, integers as decimal strings (`{"i":"..."}`), byte strings and text as
  hex (`{"b":..}`, `{"t":..}`), arrays `{"a":[..]}`, maps `{"m":[[k,v],..]}`, `{"s":"true|false|null"}`,
  and the vector's source.
* `*.expect`: `{"exit": 1, "verdict_code": ..., "source": ...}`. The draft leaves this format Open
  (its VB5); this is Trinity's.
* Expected encodings are hex literals in the generator, copied from RFC 8949 Appendix A or built
  by hand from CBOR heads, never output of the encoder under test.
* `body/schema.json` and `header/profile-table.json` are Trinity's test schema and test `typ`
  table (the draft leaves both Open, VB6 and VB4). Each `typ` names its carrier, its signers and,
  where the table says, the schema number its body's key 0 must be; no `typ` names an algorithm,
  which the key's registration does (the publisher's Decision of 2026-10-20). `thumbprint/` uses
  NIST ACVP's published ML-DSA-87 keyGen case (tgId 3, tcId 51), RFC 8032's Ed25519 test 1 key,
  RFC 6979's P-384 key (A.2.6) and a P-384 public key whose `x` begins with a zero byte; no key
  of this project's is published.
* `cose/sign1/`: single-signer carriers, `{0: SINGLE_SCHEMA, 1: payload, 2: N6_Sign1}`, each with
  its `.expect` and a `.ctx.json` naming the entry point, the `typ` table and the keys (the draft
  leaves `ctx.json` Open, VB5). `SINGLE_SCHEMA` is 0xFFFF0003, as the publisher assigned it. The
  signed samples are Ed25519, which is deterministic, and ESP384 with one fixed signature and its
  `n - s`; ML-DSA signatures are hedged, so no ML-DSA-87 sample is included and the suite signs
  and verifies one where the runtime can.
* Not included: the limit vectors at 64 KiB and 1 MiB (the suite builds them).

## Encoding defects

| Directory | Expected code |
| -- | -- |
| `nonminimal_head` | `noncanonical` |
| `indefinite_length` | `indefinite_length` |
| `float_half_1.0` | `float_forbidden` |
| `float64_int_valued` | `float_forbidden` |
| `float32` | `float_forbidden` |
| `nan` | `float_forbidden` |
| `undefined` | `simple_forbidden` |
| `simple_16` | `simple_forbidden` |
| `simple_2byte` | `simple_forbidden` |
| `tag_bignum_small` | `tag_forbidden` |
| `tag_1_datetime` | `tag_forbidden` |
| `tag_cose_sign1` | `tag_forbidden` |
| `text_nfd` | `nfc_maybe` |
| `text_bad_utf8` | `invalid_utf8` |
| `text_overlong_utf8` | `invalid_utf8` |
| `text_surrogate` | `invalid_utf8` |
| `text_key` | `key_not_uint` |
| `nested_text_key` | `key_not_uint` |
| `negative_map_key` | `key_not_uint` |
| `map_key_over_u32` | `key_not_uint` |
| `bstr_key` | `key_not_uint` |
| `swap_keys` | `noncanonical` |
| `duplicate_key` | `duplicate_key` |
| `int_below_dcbor_range` | `int_out_of_range` |
| `trailing_bytes` | `trailing_bytes` |
| `truncated` | `truncated` |
| `too_deep` | `too_deep` |
| `not_well_formed` | `not_well_formed` |

## Body defects (under `body/schema.json`)

| Directory | Expected code |
| -- | -- |
| `no_schema_version` | `schema_version_missing` |
| `bool_schema_version` | `key_not_uint` |
| `negative_schema_version` | `key_not_uint` |
| `carrier_schema_key0` | `schema_reserved` |
| `test_schema_outside_test_mode` | `test_schema_outside_test_mode` |
| `unknown_schema` | `unknown_schema` |
| `unknown_key` | `unknown_key` |
| `field_missing` | `field_missing` |
| `field_type_mismatch` | `field_type_mismatch` |
| `set_unsorted` | `set_not_canonical` |
| `set_duplicate` | `set_not_canonical` |
| `not_a_map` | `body_not_map` |

## Header defects (under `header/profile-table.json`)

| Directory | Expected code |
| -- | -- |
| `alg_not_mldsa87` | `alg_not_permitted` |
| `content_type` | `content_type_forbidden` |
| `crit` | `header_label_forbidden` |
| `label_0` | `header_label_forbidden` |
| `label_5` | `header_label_forbidden` |
| `label_negative` | `header_label_forbidden` |
| `label_hash_envelope` | `header_label_forbidden` |
| `alg_missing` | `header_missing` |
| `kid_missing` | `header_missing` |
| `typ_missing` | `header_missing` |
| `typ_uint` | `typ_unexpected` |
| `typ_not_in_table` | `typ_unexpected` |
| `cwt_without_scitt_typ` | `header_label_forbidden` |
| `kid_wrong_size` | `header_value_invalid` |
| `header_noncanonical` | `header_noncanonical` |

## Digest defects

| Directory | Expected code |
| -- | -- |
| `digest_alg_not_permitted` | `digest_alg_not_permitted` |
| `digest_length_mismatch` | `digest_length_mismatch` |
| `digest_not_array` | `field_type_mismatch` |

## Single-signer carriers (`cose/sign1/`)

| Sample | Entry point | Exit | Expected code |
| -- | -- | -- | -- |
| `ed25519_single` | `commercial` | 0 | `claim` |
| `ed25519_single_at_nss` | `nss` | 1 | `alg_not_permitted` |
| `ed25519_signature_flipped` | `commercial` | 1 | `signature_invalid` |
| `ed25519_no_issuer` | `commercial` | 1 | `issuer_missing` |
| `ed25519_typ_schema_mismatch` | `commercial` | 1 | `typ_schema_mismatch` |
| `ed25519_key_registered_as_mldsa87` | `commercial` | 1 | `alg_not_permitted` |
| `carrier_key0_envelope` | `commercial` | 1 | `carrier_malformed` |
| `carrier_extra_key` | `commercial` | 1 | `carrier_malformed` |
| `carrier_no_sign1` | `commercial` | 1 | `carrier_malformed` |
| `carrier_payload_text` | `commercial` | 1 | `carrier_malformed` |
| `carrier_not_map` | `commercial` | 1 | `carrier_malformed` |
| `carrier_keys_out_of_order` | `commercial` | 1 | `noncanonical` |
| `sign1_attached` | `commercial` | 1 | `carrier_malformed` |
| `sign1_tagged` | `commercial` | 1 | `tag_forbidden` |
| `sign1_unprotected_kid` | `commercial` | 1 | `header_not_protected` |
| `pair_typ_in_single_carrier` | `commercial` | 1 | `wrong_carrier_for_typ` |
| `esp384_single` | `commercial` | 0 | `claim` |
| `esp384_n_minus_s` | `commercial` | 0 | `claim` |
| `esp384_at_nss` | `nss` | 1 | `alg_not_permitted` |
| `esp384_signature_der` | `commercial` | 1 | `signature_encoding` |
| `esp384_signature_95_bytes` | `commercial` | 1 | `signature_encoding` |
| `esp384_signature_97_bytes` | `commercial` | 1 | `signature_encoding` |
| `esp384_signature_flipped` | `commercial` | 1 | `signature_invalid` |
| `esp384_key_compressed` | `commercial` | 1 | `key_invalid` |
| `esp384_key_p256` | `commercial` | 1 | `key_invalid` |
| `esp384_key_registered_as_ed25519` | `commercial` | 1 | `alg_not_permitted` |
