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
  table (the draft leaves both Open, VB6 and VB4). `thumbprint/` uses NIST ACVP's published
  ML-DSA-87 keyGen case (tgId 3, tcId 51); no key of this project's is published.
* Not included: the limit vectors at 64 KiB and 1 MiB (the suite builds them), and COSE_Sign1
  samples (ML-DSA signatures are hedged, so a sample is one valid signature among many; the
  suite signs and verifies where the runtime can).

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
| `text_nfd` | `not_nfc` |
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
| `unknown_schema` | `unknown_schema` |
| `unknown_key` | `unknown_key` |
| `required_key_missing` | `required_key_missing` |
| `wrong_type` | `wrong_type` |
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
| `alg_missing` | `header_not_protected` |
| `kid_missing` | `header_not_protected` |
| `typ_missing` | `header_not_protected` |
| `typ_uint` | `typ_unexpected` |
| `typ_not_in_table` | `typ_unexpected` |
| `cwt_without_scitt_typ` | `header_label_forbidden` |
| `kid_wrong_size` | `kid_not_thumbprint` |
| `header_noncanonical` | `header_noncanonical` |

## Digest defects

| Directory | Expected code |
| -- | -- |
| `digest_alg_not_permitted` | `digest_alg_not_permitted` |
| `digest_length_mismatch` | `digest_length_mismatch` |
| `digest_not_array` | `digest_malformed` |
