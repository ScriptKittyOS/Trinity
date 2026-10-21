# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Writes Trinity's provisional N6 vectors (slices 138 to 140) into the directory given, in the layout of the
# N6 profile v0 draft r3, section 10:
#
#     elixir scripts/n6_vectors.exs test/fixtures/n6
#
# Every expected encoding below is a hex literal, either copied from RFC 8949 Appendix A or built by
# hand from CBOR heads, so that no vector is the encoder's opinion of itself: the encoder under test
# (`Trinity.N6.CBOR`) is not loaded here. This script only turns each literal into the files the
# layout asks for (the description, the diagnostic notation, the expected outcome) and writes
# SHA384SUMS in the form `sha384sum -c` reads. Running it twice writes the same bytes.
#
# The limit vectors at 64 KiB and 1 MiB are not checked in; the suite builds them in memory by the
# rule written in Trinity.N6.Profile.

defmodule N6Vectors do
  @typ "application/vnd.example.test.v1+cose"
  @typ_scitt "application/vnd.example.scitt-test.v1+cose"
  @typ_other "application/vnd.example.other.v1+cose"
  # Slice 139: the `typ` its Ed25519 (-19) samples use on the `commercial` profile, and one whose entry
  # needs two signers, which a single-signer carrier must refuse. Since slice 140 a `typ` names no
  # algorithm (the publisher's Decision of 2026-10-20, point 3): the key's registration does. The
  # names are only names.
  @typ_ed "application/vnd.example.test-ed25519.v1+cose"
  @typ_twin "application/vnd.example.twin-test.v1+cose"
  # Slice 140: the `typ` the ESP384 (-51) samples use.
  @typ_esp "application/vnd.example.test-esp384.v1+cose"

  # Slice 140: every full-payload single-signer body carries key 1, `issuer` (the publisher's Decision
  # of 2026-10-20, point 3), here under the RFC 6761 `.invalid` name.
  @issuer "trinity:test.invalid"

  # RFC 8032 section 7.1, test 1: a published Ed25519 key, so no key of this tree's is published.
  @ed_pub "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"

  # Ed25519 over the sample's ToBeSigned (below) under that key's secret
  # (9d61b19d...1cae7f60, RFC 8032 section 7.1). Ed25519 is deterministic, so this is the only valid
  # signature, and it is a literal so the generator runs where the runtime refuses Ed25519 (FIPS
  # mode). The suite checks it signs and verifies wherever the runtime has Ed25519. `@ed_sig` is
  # slice 139's, over the body {0: 1, 16: "slice 139"}, which has no `issuer`; since slice 140 that
  # sample is `issuer_missing`. `@ed_sig_issuer` is over the same body with key 1, `@ed_sig_schema_2`
  # over it with key 0 = 2.
  @ed_sig "44f793ebf76a054b798344893478ce4d19985eb9b8e813e6a99fa2920cc45f955c8fa32ce1307b6673c5418419cb81b0e35c7018966622bcf179ecd623740703"
  @ed_sig_issuer "ff0ca9413ae325a29a74f71ff62f8cc8d3197d2aa715ac1e43aa74c112c0d51b5325be34e6c097d5e120f9646fdaf7f0c40739e3750a5b49275f2d04bcc07d00"
  @ed_sig_schema_2 "23b8e030b47818e0d28cad5805c155bed332b4fcb9169001acc38f3868278fb5ad4600d75f1ff50f2f693668860ef507ce1ee81c7a8fe9ae46eb83d083649904"

  # Slice 140, ESP384: RFC 6979 appendix A.2.6's published P-384 key (private
  # 6b9d3dad...60d2edf5), its uncompressed public point, and one signature it made, as the 96-byte
  # r || s, over the ESP384 sample's ToBeSigned. ECDSA here is randomised, so this is one valid
  # signature of many, fixed as a literal; `n - s` is the other the samples use. The same signature as
  # :crypto's DER (103 bytes) is the `signature_encoding` sample.
  @ec_pub "04ec3a4e415b4e19a4568618029f427fa5da9a8bc4ae92e02e06aae5286b300c64def8f0ea9055866064a254515480bc138015d9b72d7d57244ea8ef9ac0c621896708a59367f9dfb9f54ca84b3f1c9db1288b231c3ae0d4fe7344fd2533264720"
  @esp_sig "bed4807824fa21510c61d976ae13784810bbeb7dffd42d4ac341417bb832abed12514db5fdf349d981fea339633e97e1740e49429ab74ee078734ba75bcb3eee60de1507f3754b764cb820f3eae1102b7369d2d1bf0ecd6d39bac148aec3bb6b"
  @esp_der "3065023100bed4807824fa21510c61d976ae13784810bbeb7dffd42d4ac341417bb832abed12514db5fdf349d981fea339633e97e10230740e49429ab74ee078734ba75bcb3eee60de1507f3754b764cb820f3eae1102b7369d2d1bf0ecd6d39bac148aec3bb6b"
  # A P-384 public key whose x begins with a zero byte, generated for the thumbprint vector only (no
  # private key is kept): a thumbprint that dropped the leading zero would give another kid.
  @ec_pub_leading_zero "0400edc54551ef7c1c37c526427a30628bb4495fdd9721418fe5bc36358e0e3c67dabd04b38ffc8b355fd6f0af9f04c51f07fce50fca9d02d204ecba8bf37aee11fb29954efdd36a3ea368754a860ade1cf280b879084a3bbff3a15529f975f8d3"
  # RFC 6979 appendix A.2.5's P-256 public key: registered as ESP384, a key on the wrong curve.
  @p256_pub "0460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299"
  # The P-384 group order, for `n - s`.
  @p384_n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973

  # The single-signer carrier's schema number, 0xFFFF0003: a placeholder at slice 139, assigned by
  # the publisher's Decision of 2026-10-20 (point 2).
  @single_schema "1a ff ff 00 03"

  # FIPS 180-2, Appendix D.1: SHA-384("abc").
  @sha384_abc "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"

  def run([root]) do
    acvp = Path.expand("../priv/kat/acvp/mldsa87_keygen.json", __DIR__) |> File.read!() |> JSON.decode!()
    pub = Base.decode16!(acvp["pk"])
    2592 = byte_size(pub)

    # RFC 9679 section 3 over the AKP members of RFC 9964 section 6: {1: 7, 3: -50, -1: pub},
    # keys in bytewise order 0x01, 0x03, 0x20, a 2,592-byte string's head being 59 0a 20.
    thumb_input = h("a3 01 07 03 38 31 20 59 0a 20") <> pub
    kid = :crypto.hash(:sha384, thumb_input)

    # RFC 9679 section 4.1 over the OKP members of RFC 9053 section 7.1: {1: 1, -1: 6, -2: x}, keys in
    # bytewise order 0x01, 0x20, 0x21, a 32-byte string's head being 58 20. No `alg`: the key's
    # registration names it.
    ed_pub = h(@ed_pub)
    ed_kid = :crypto.hash(:sha384, h("a3 01 01 20 06 21 58 20") <> ed_pub)

    # RFC 9679 over the EC2 members of RFC 9053 section 7.1: {1: 2, -1: 2, -2: x, -3: y}, keys in
    # bytewise order 0x01, 0x20, 0x21, 0x22, each coordinate exactly 48 bytes (58 30): 107 bytes.
    ec_kid = ec2_kid(h(@ec_pub))

    File.rm_rf!(root)

    for {id, hex, desc, source} <- encoding_positive(), do: positive(root, "encoding", id, h(hex), desc, source)
    for {defect, id, hex, code, source} <- encoding_negative(), do: negative(root, "encoding", defect, id, h(hex), code, source)
    for {id, hex, desc} <- body_positive(), do: positive(root, "body", id, h(hex), desc, "hand")
    for {defect, id, hex, code} <- body_negative(), do: negative(root, "body", defect, id, h(hex), code, "hand")
    write(root, "body/schema.json", json(test_schema()))

    header = header_vectors(kid, ed_kid, ec_kid)
    for {id, bytes} <- header.positive, do: write(root, "header/positive/#{id}.cbor", bytes)
    for {defect, id, bytes, code} <- header.negative, do: negative(root, "header", defect, id, bytes, code, "hand")
    write(root, "header/profile-table.json", json(profile_table()))

    write(root, "thumbprint/acvp_mldsa87_tg3_tc51.pub", pub)
    write(root, "thumbprint/acvp_mldsa87_tg3_tc51.kid", kid)
    write(root, "thumbprint/rfc8032_test1_ed25519.pub", ed_pub)
    write(root, "thumbprint/rfc8032_test1_ed25519.kid", ed_kid)
    write(root, "thumbprint/rfc6979_a26_p384.pub", h(@ec_pub))
    write(root, "thumbprint/rfc6979_a26_p384.kid", ec_kid)
    write(root, "thumbprint/p384_x_leading_zero.pub", h(@ec_pub_leading_zero))
    write(root, "thumbprint/p384_x_leading_zero.kid", ec2_kid(h(@ec_pub_leading_zero)))

    # Keys a sample's context registers on purpose wrongly: the RFC 6979 key compressed, and a P-256
    # point (RFC 6979 appendix A.2.5's public key), each registered as ESP384.
    <<4, ec_x::binary-size(48), ec_y::binary-size(48)>> = h(@ec_pub)
    write(root, "thumbprint/rfc6979_a26_p384_compressed.pub", <<2 + rem(:binary.last(ec_y), 2)>> <> ec_x)
    write(root, "thumbprint/rfc6979_a25_p256.pub", h(@p256_pub))

    for {id, bytes, exit, code, entry, keys} <- sign1_samples(kid, ed_kid, ec_kid),
        do: sample(root, id, bytes, exit, code, entry, keys)

    abc = "abc"
    digest = :crypto.hash(:sha384, abc)
    ^digest = Base.decode16!(@sha384_abc, case: :lower)

    # ForeignRef {0: [-43, digest], 1: 3, 2: "application/octet-stream"}
    ref = h("a3 00 82 38 2a 58 30") <> digest <> h("01 03 02 78 18") <> "application/octet-stream"
    write(root, "digest/abc.in", abc)
    write(root, "digest/abc.ref.cbor", ref)

    for {defect, id, bytes, code} <- digest_negative(),
        do: negative(root, "digest", defect, id, bytes, code, "hand")

    write(root, "VERSION", "n6/v0 draft r3 and the publisher's answers of 2026-10-19 and 2026-10-20 PROVISIONAL (Trinity candidate set)\n")
    write(root, "README.md", readme(header.negative, sign1_samples(kid, ed_kid, ec_kid)))
    write_sums(root)
  end

  # The README lists every negative directory with its expected code, derived from the lists above.
  defp readme(header_negative, samples) do
    rows = fn vectors ->
      vectors
      |> Enum.map(fn v -> {elem(v, 0), code_of(v)} end)
      |> Enum.uniq()
      |> Enum.map_join("\n", fn {defect, code} -> "| `#{defect}` | `#{code}` |" end)
    end

    """
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
    #{rows.(encoding_negative())}

    ## Body defects (under `body/schema.json`)

    | Directory | Expected code |
    | -- | -- |
    #{rows.(body_negative())}

    ## Header defects (under `header/profile-table.json`)

    | Directory | Expected code |
    | -- | -- |
    #{rows.(header_negative)}

    ## Digest defects

    | Directory | Expected code |
    | -- | -- |
    #{rows.(digest_negative())}

    ## Single-signer carriers (`cose/sign1/`)

    | Sample | Entry point | Exit | Expected code |
    | -- | -- | -- | -- |
    #{Enum.map_join(samples, "\n", fn {id, _, exit, code, entry, _keys} -> "| `#{id}` | `#{entry}` | #{exit} | `#{code}` |" end)}
    """
  end

  # Encoding vectors carry a source after the code; the other lists do not.
  defp code_of(v) do
    case v do
      {_defect, _id, _bytes, code, _source} -> code
      {_defect, _id, _bytes, code} -> code
    end
  end

  ## Encoding: positive

  # {id, hex, description, source}
  defp encoding_positive do
    a = "RFC 8949 Appendix A"

    [
      {"uint_0", "00", {:i, 0}, a},
      {"uint_1", "01", {:i, 1}, a},
      {"uint_10", "0a", {:i, 10}, a},
      {"uint_23", "17", {:i, 23}, a},
      {"uint_24", "18 18", {:i, 24}, a},
      {"uint_25", "18 19", {:i, 25}, a},
      {"uint_100", "18 64", {:i, 100}, a},
      {"uint_1000", "19 03 e8", {:i, 1000}, a},
      {"uint_1000000", "1a 00 0f 42 40", {:i, 1_000_000}, a},
      {"uint_1000000000000", "1b 00 00 00 e8 d4 a5 10 00", {:i, 1_000_000_000_000}, a},
      {"uint_max_u64", "1b ff ff ff ff ff ff ff ff", {:i, 18_446_744_073_709_551_615}, a},
      {"nint_1", "20", {:i, -1}, a},
      {"nint_10", "29", {:i, -10}, a},
      {"nint_100", "38 63", {:i, -100}, a},
      {"nint_1000", "39 03 e7", {:i, -1000}, a},
      {"nint_min_i64", "3b 7f ff ff ff ff ff ff ff", {:i, -9_223_372_036_854_775_808}, "hand: -2^63, the bottom of E4"},
      {"uint_255", "18 ff", {:i, 255}, "hand: the top of a one-byte argument"},
      {"uint_256", "19 01 00", {:i, 256}, "hand: the bottom of a two-byte argument"},
      {"uint_65535", "19 ff ff", {:i, 65_535}, "hand"},
      {"uint_65536", "1a 00 01 00 00", {:i, 65_536}, "hand"},
      {"uint_4294967295", "1a ff ff ff ff", {:i, 4_294_967_295}, "hand"},
      {"uint_4294967296", "1b 00 00 00 01 00 00 00 00", {:i, 4_294_967_296}, "hand"},
      {"false", "f4", {:s, "false"}, a},
      {"true", "f5", {:s, "true"}, a},
      {"null", "f6", {:s, "null"}, a},
      {"bstr_empty", "40", {:b, ""}, a},
      {"bstr_01020304", "44 01 02 03 04", {:b, <<1, 2, 3, 4>>}, a},
      {"tstr_empty", "60", {:t, ""}, a},
      {"tstr_a", "61 61", {:t, "a"}, a},
      {"tstr_ietf", "64 49 45 54 46", {:t, "IETF"}, a},
      {"tstr_quote_backslash", "62 22 5c", {:t, "\"\\"}, a},
      {"tstr_u_umlaut", "62 c3 bc", {:t, "ü"}, a},
      {"tstr_water", "63 e6 b0 b4", {:t, "水"}, a},
      {"tstr_aegean_10151", "64 f0 90 85 91", {:t, "\u{10151}"}, a},
      {"array_empty", "80", {:a, []}, a},
      {"array_123", "83 01 02 03", {:a, [{:i, 1}, {:i, 2}, {:i, 3}]}, a},
      {"array_nested", "83 01 82 02 03 82 04 05",
       {:a, [{:i, 1}, {:a, [{:i, 2}, {:i, 3}]}, {:a, [{:i, 4}, {:i, 5}]}]}, a},
      {"array_25", "98 19 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 18 18 19",
       {:a, Enum.map(1..25, &{:i, &1})}, a},
      {"map_empty", "a0", {:m, []}, a},
      {"map_1_2_3_4", "a2 01 02 03 04", {:m, [{{:i, 1}, {:i, 2}}, {{:i, 3}, {:i, 4}}]}, a},
      {"map_keys_across_heads", "a5 0a 00 17 01 18 18 02 18 64 03 19 03 e8 04",
       {:m, [{{:i, 10}, {:i, 0}}, {{:i, 23}, {:i, 1}}, {{:i, 24}, {:i, 2}}, {{:i, 100}, {:i, 3}}, {{:i, 1000}, {:i, 4}}]},
       "hand: unsigned keys with 0-, 1- and 2-byte arguments, in bytewise order"},
      {"map_key_max_u32", "a1 1a ff ff ff ff 00", {:m, [{{:i, 4_294_967_295}, {:i, 0}}]}, "hand: the top of E2"},
      {"map_mixed_values", "a4 00 01 01 41 ff 02 61 78 03 82 f5 f6",
       {:m,
        [
          {{:i, 0}, {:i, 1}},
          {{:i, 1}, {:b, <<0xFF>>}},
          {{:i, 2}, {:t, "x"}},
          {{:i, 3}, {:a, [{:s, "true"}, {:s, "null"}]}}
        ]}, "hand"},
      {"depth_16", String.duplicate("81 ", 15) <> "80", nest(16), "hand: the depth limit, counted as Trinity.N6.Profile states"}
    ]
  end

  defp nest(1), do: {:a, []}
  defp nest(n), do: {:a, [nest(n - 1)]}

  ## Encoding: negative

  # {defect, id, hex, code, source}
  defp encoding_negative do
    a = "RFC 8949 Appendix A"

    [
      {"nonminimal_head", "uint_0_in_one_byte", "18 00", "noncanonical", "hand"},
      {"nonminimal_head", "uint_23_in_one_byte", "18 17", "noncanonical", "hand"},
      {"nonminimal_head", "uint_255_in_two_bytes", "19 00 ff", "noncanonical", "hand"},
      {"nonminimal_head", "length_in_two_bytes", "59 00 01 00", "noncanonical", "hand"},
      {"nonminimal_head", "nested_in_array", "81 18 05", "noncanonical", "hand"},
      {"indefinite_length", "bstr", "5f 42 01 02 43 03 04 05 ff", "indefinite_length", a},
      {"indefinite_length", "tstr", "7f 65 73 74 72 65 61 64 6d 69 6e 67 ff", "indefinite_length", a},
      {"indefinite_length", "array_empty", "9f ff", "indefinite_length", a},
      {"indefinite_length", "map", "bf 01 02 ff", "indefinite_length", "hand"},
      {"indefinite_length", "nested_in_array", "83 01 82 02 03 9f 04 05 ff", "indefinite_length", a},
      {"float_half_1.0", "top", "f9 3c 00", "float_forbidden", a},
      {"float_half_1.0", "zero", "f9 00 00", "float_forbidden", a},
      {"float_half_1.0", "negative_zero", "f9 80 00", "float_forbidden", a},
      {"float64_int_valued", "1e300", "fb 7e 37 e4 3c 88 00 75 9c", "float_forbidden", a},
      {"float64_int_valued", "nested_in_map_value", "a1 01 fb 3f f0 00 00 00 00 00 00", "float_forbidden", "hand: 1.0 as a double"},
      {"float32", "100000", "fa 47 c3 50 00", "float_forbidden", a},
      {"nan", "half", "f9 7e 00", "float_forbidden", a},
      {"nan", "single", "fa 7f c0 00 00", "float_forbidden", a},
      {"nan", "double", "fb 7f f8 00 00 00 00 00 00", "float_forbidden", a},
      {"undefined", "top", "f7", "simple_forbidden", a},
      {"simple_16", "top", "f0", "simple_forbidden", a},
      {"simple_2byte", "simple_255", "f8 ff", "simple_forbidden", a},
      {"simple_2byte", "simple_32", "f8 20", "simple_forbidden", "hand"},
      {"tag_bignum_small", "positive_bignum_1", "c2 41 01", "tag_forbidden", "hand"},
      {"tag_bignum_small", "rfc_2_64", "c2 49 01 00 00 00 00 00 00 00 00", "tag_forbidden", a},
      {"tag_1_datetime", "epoch", "c1 1a 51 4b 67 b0", "tag_forbidden", a},
      {"tag_1_datetime", "nested_in_array", "81 c1 1a 51 4b 67 b0", "tag_forbidden", "hand"},
      {"tag_cose_sign1", "tag_18", "d2 80", "tag_forbidden", "hand: COSE_Sign1's tag inside N6 bytes"},
      # Slice 142: U+0301 is NFC_QC Maybe, so the decomposed form is `nfc_maybe` (draft v0.1-r7
      # section 10.4).
      {"text_nfd", "e_combining_acute", "63 65 cc 81", "nfc_maybe", "hand: U+0065 U+0301"},
      {"text_nfd", "nested_in_map_value", "a1 01 63 65 cc 81", "nfc_maybe", "hand"},
      {"text_bad_utf8", "lone_ff", "62 61 ff", "invalid_utf8", "hand"},
      {"text_bad_utf8", "truncated_sequence", "62 61 c3", "invalid_utf8", "hand"},
      {"text_overlong_utf8", "slash", "62 c0 af", "invalid_utf8", "hand: '/' in two bytes"},
      {"text_surrogate", "d800", "63 ed a0 80", "invalid_utf8", "hand: U+D800 in UTF-8 form"},
      {"text_key", "rfc_map", "a2 61 61 01 61 62 82 02 03", "key_not_uint", a},
      {"text_key", "top", "a1 61 61 01", "key_not_uint", "hand"},
      {"nested_text_key", "in_array", "82 61 61 a1 61 62 61 63", "key_not_uint", a},
      {"negative_map_key", "minus_1", "a1 20 00", "key_not_uint", "hand"},
      {"map_key_over_u32", "two_to_32", "a1 1b 00 00 00 01 00 00 00 00 00", "key_not_uint", "hand"},
      {"bstr_key", "h01", "a1 41 01 00", "key_not_uint", "hand"},
      {"swap_keys", "2_then_1", "a2 02 00 01 00", "noncanonical", "hand"},
      {"swap_keys", "24_then_23", "a2 18 18 00 17 00", "noncanonical", "hand: a longer head after a shorter key"},
      {"duplicate_key", "1_twice", "a2 01 00 01 01", "duplicate_key", "hand"},
      {"duplicate_key", "nested", "81 a2 05 00 05 00", "duplicate_key", "hand"},
      {"int_below_dcbor_range", "minus_2_63_minus_1", "3b 80 00 00 00 00 00 00 00", "int_out_of_range", "hand: -2^63-1"},
      {"int_below_dcbor_range", "rfc_minus_2_64", "3b ff ff ff ff ff ff ff ff", "int_out_of_range", a},
      {"trailing_bytes", "two_items", "00 00", "trailing_bytes", "hand"},
      {"trailing_bytes", "after_array", "80 00", "trailing_bytes", "hand"},
      {"truncated", "head_argument", "19 01", "truncated", "hand"},
      {"truncated", "bstr_body", "44 01 02", "truncated", "hand"},
      {"truncated", "array_items", "83 01 02", "truncated", "hand"},
      {"truncated", "empty_input", "", "truncated", "hand"},
      {"too_deep", "depth_17", String.duplicate("81 ", 16) <> "80", "too_deep", "hand: one past the depth limit"},
      {"not_well_formed", "ai_28", "1c", "not_well_formed", "hand: reserved additional information"},
      {"not_well_formed", "ai_30_nint", "3e", "not_well_formed", "hand"},
      {"not_well_formed", "lone_break", "ff", "not_well_formed", "hand"},
      {"not_well_formed", "uint_ai_31", "1f", "not_well_formed", "hand"},
      {"not_well_formed", "f8_below_32", "f8 10", "not_well_formed", "hand: RFC 8949 section 3.3"}
    ]
  end

  ## Body, under the published test schema (body/schema.json)

  defp test_schema do
    %{
      "provisional" => true,
      "note" =>
        "Trinity's test schema for the body vectors. The draft leaves test schemas Open (VB6); this one is Trinity's.",
      "kind" => "trinity.test",
      "schema_version" => 1,
      "fields" => [
        %{"key" => 16, "name" => "name", "type" => "tstr", "required" => true},
        %{"key" => 17, "name" => "count", "type" => "uint", "required" => false},
        %{"key" => 18, "name" => "members", "type" => "set of uint", "required" => false}
      ]
    }
  end

  defp body_positive do
    [
      {"minimal", "a2 00 01 10 61 78", {:m, [{{:i, 0}, {:i, 1}}, {{:i, 16}, {:t, "x"}}]}},
      {"all_fields", "a4 00 01 10 61 78 11 05 12 83 01 02 03",
       {:m,
        [
          {{:i, 0}, {:i, 1}},
          {{:i, 16}, {:t, "x"}},
          {{:i, 17}, {:i, 5}},
          {{:i, 18}, {:a, [{:i, 1}, {:i, 2}, {:i, 3}]}}
        ]}},
      {"set_sorted_by_encoded_bytes", "a3 00 01 10 61 78 12 83 17 18 18 19 01 00",
       {:m,
        [
          {{:i, 0}, {:i, 1}},
          {{:i, 16}, {:t, "x"}},
          {{:i, 18}, {:a, [{:i, 23}, {:i, 24}, {:i, 256}]}}
        ]}}
    ]
  end

  # {defect, id, hex, code}
  defp body_negative do
    [
      {"no_schema_version", "no_key_0", "a1 10 61 78", "schema_version_missing"},
      {"bool_schema_version", "true", "a2 00 f5 10 61 78", "key_not_uint"},
      {"negative_schema_version", "minus_1", "a2 00 20 10 61 78", "key_not_uint"},
      {"carrier_schema_key0", "envelope_schema", "a2 00 1a ff ff 00 01 10 61 78", "schema_reserved"},
      {"carrier_schema_key0", "top_of_range", "a2 00 1a ff ff ff ff 10 61 78", "schema_reserved"},
      # Slice 140, the publisher's order of 2026-10-20 17:27Z: a number in the shared test block is
      # refused as such outside test mode, before `unknown_schema` could answer for it.
      {"test_schema_outside_test_mode", "block_0x80", "a2 00 1a 80 00 01 01 10 61 78", "test_schema_outside_test_mode"},
      {"unknown_schema", "version_2", "a2 00 02 10 61 78", "unknown_schema"},
      {"unknown_schema", "reserved_block_0x90", "a2 00 1a 90 00 00 00 10 61 78", "unknown_schema"},
      {"unknown_schema", "trinity_block_unissued", "a2 00 1a 83 00 ff 01 10 61 78", "unknown_schema"},
      {"unknown_key", "key_19", "a3 00 01 10 61 78 13 00", "unknown_key"},
      # Slice 142: draft v0.1-r7's names for these two (section 3.6, B8).
      {"field_missing", "no_name", "a1 00 01", "field_missing"},
      {"field_type_mismatch", "name_as_uint", "a2 00 01 10 01", "field_type_mismatch"},
      {"set_unsorted", "2_then_1", "a3 00 01 10 61 78 12 82 02 01", "set_not_canonical"},
      {"set_unsorted", "longer_head_first", "a3 00 01 10 61 78 12 82 18 18 17", "set_not_canonical"},
      {"set_duplicate", "1_twice", "a3 00 01 10 61 78 12 82 01 01", "set_not_canonical"},
      {"not_a_map", "array", "82 00 01", "body_not_map"}
    ]
  end

  ## Header (decoded as a protected header, not as a body)

  defp profile_table do
    %{
      "provisional" => true,
      "note" => "Trinity's test profile table for the header vectors (the draft leaves its CDDL Open, VB4).",
      "typ" => [
        %{"typ" => @typ, "carrier" => "single", "signers" => "single", "scitt" => false},
        %{"typ" => @typ_scitt, "carrier" => "single", "signers" => "single", "scitt" => true},
        %{"typ" => @typ_ed, "carrier" => "single", "signers" => "single", "scitt" => false, "schema" => 1},
        %{"typ" => @typ_esp, "carrier" => "single", "signers" => "single", "scitt" => false, "schema" => 1},
        %{"typ" => @typ_twin, "carrier" => "envelope", "signers" => "pair", "scitt" => false}
      ]
    }
  end

  defp header_vectors(kid, ed_kid, ec_kid) do
    alg = h("01 38 31")
    kid_pair = h("04 58 30") <> kid
    typ = h("10 78 24") <> @typ
    ed_alg = h("01 32")
    ed_kid_pair = h("04 58 30") <> ed_kid
    typ_ed = h("10 78 2c") <> @typ_ed
    typ_scitt = h("10 78 2a") <> @typ_scitt
    typ_other = h("10 78 25") <> @typ_other
    esp_alg = h("01 38 32")
    ec_kid_pair = h("04 58 30") <> ec_kid
    typ_esp = h("10 78 2b") <> @typ_esp
    cwt = h("0f a2 01 63") <> "iss" <> h("02 63") <> "sub"

    %{
      positive: [
        {"alg_kid_typ", h("a3") <> alg <> kid_pair <> typ},
        {"alg_kid_cwt_typ_scitt", h("a4") <> alg <> kid_pair <> cwt <> typ_scitt},
        {"ed25519_alg_kid_typ", h("a3") <> ed_alg <> ed_kid_pair <> typ_ed},
        # Slice 140: since a `typ` names no algorithm, these decode at `commercial` (slice 139 had them
        # as `alg_not_bound_to_typ`); the key's registration decides, in the cose samples.
        {"ed25519_alg_under_any_typ", h("a3") <> ed_alg <> ed_kid_pair <> typ},
        {"esp384_alg_kid_typ", h("a3") <> esp_alg <> ec_kid_pair <> typ_esp}
      ],
      negative: [
        {"alg_not_mldsa87", "mldsa65", h("a3 01 38 30") <> kid_pair <> typ, "alg_not_permitted"},
        {"alg_not_mldsa87", "eddsa", h("a3 01 27") <> kid_pair <> typ, "alg_not_permitted"},
        # Slice 140: ES384 (-35), the polymorphic identifier RFC 9864 deprecates, is not ESP384.
        {"alg_not_mldsa87", "es384", h("a3 01 38 22") <> ec_kid_pair <> typ_esp, "alg_not_permitted"},
        {"content_type", "label_3", h("a4") <> alg <> h("03 61 78") <> kid_pair <> typ, "content_type_forbidden"},
        {"crit", "label_2", h("a4") <> alg <> h("02 81 01") <> kid_pair <> typ, "header_label_forbidden"},
        {"label_0", "label_0", h("a4 00 00") <> alg <> kid_pair <> typ, "header_label_forbidden"},
        {"label_5", "iv", h("a4") <> alg <> kid_pair <> h("05 41 00") <> typ, "header_label_forbidden"},
        {"label_negative", "minus_1", h("a4") <> alg <> kid_pair <> typ <> h("20 00"), "header_label_forbidden"},
        {"label_hash_envelope", "label_258", h("a4") <> alg <> kid_pair <> typ <> h("19 01 02 38 2a"), "header_label_forbidden"},
        # Slice 142: draft v0.1-r7 H3 and H4 name a missing label `header_missing` and a `kid` of the
        # wrong shape `header_value_invalid`.
        {"alg_missing", "no_label_1", h("a2") <> kid_pair <> typ, "header_missing"},
        {"kid_missing", "no_label_4", h("a2") <> alg <> typ, "header_missing"},
        {"typ_missing", "no_label_16", h("a2") <> alg <> kid_pair, "header_missing"},
        {"typ_uint", "typ_1", h("a3") <> alg <> kid_pair <> h("10 01"), "typ_unexpected"},
        {"typ_not_in_table", "other", h("a3") <> alg <> kid_pair <> typ_other, "typ_unexpected"},
        {"cwt_without_scitt_typ", "cwt_on_plain_typ", h("a4") <> alg <> kid_pair <> cwt <> typ, "header_label_forbidden"},
        {"kid_wrong_size", "kid_32", h("a3") <> alg <> h("04 58 20") <> binary_part(kid, 0, 32) <> typ, "header_value_invalid"},
        {"header_noncanonical", "typ_before_kid", h("a3") <> alg <> typ <> kid_pair, "header_noncanonical"},
        {"header_noncanonical", "nonminimal_label", h("a3 18 01 38 31") <> kid_pair <> typ, "header_noncanonical"},
        {"header_noncanonical", "trailing_byte", h("a3") <> alg <> kid_pair <> typ <> h("00"), "header_noncanonical"}
      ]
    }
  end

  ## Single-signer carriers (slices 139 and 140)

  # {id, carrier bytes, exit, verdict code, entry point, keys}. `keys` is what the sample's context
  # registers: nil for the three published keys, each under its own algorithm. Every signature is over
  # ["Signature1", protected, h'', payload], RFC 9052 section 4.4. The Ed25519 payload is the N6 body
  # {0: 1, 1: "trinity:test.invalid", 16: "slice 139"}, the ESP384 payload the same with "slice 140".
  defp sign1_samples(kid, ed_kid, ec_kid) do
    payload = body(h("01"), "slice 139")
    payload_field = h("01 58 24") <> payload
    protected = h("a3 01 32 04 58 30") <> ed_kid <> h("10 78 2c") <> @typ_ed
    sig = h(@ed_sig_issuer)
    sign1 = h("84 58 65") <> protected <> h("a0 f6 58 40") <> sig
    good = h("a3 00") <> h(@single_schema) <> payload_field <> h("02") <> sign1
    carrier = fn payload_field, sign1 -> h("a3 00") <> h(@single_schema) <> payload_field <> h("02") <> sign1 end
    ed_sign1 = fn sig -> h("84 58 65") <> protected <> h("a0 f6 58 40") <> sig end

    flipped = binary_part(sig, 0, 63) <> <<:binary.last(sig) |> Bitwise.bxor(1)>>
    twin_protected = h("a3") <> h("01 38 31") <> h("04 58 30") <> kid <> h("10 78 29") <> @typ_twin
    twin_sign1 = h("84 58 63") <> twin_protected <> h("a0 f6 59 12 13") <> :binary.copy(<<0>>, 4627)

    # Slice 139's body, without `issuer`, under its own literal signature; and the body with key 0 = 2.
    no_issuer = h("01 4e a2 00 01 10 69") <> "slice 139"
    schema_2 = h("01 58 24") <> body(h("02"), "slice 139")

    esp_payload_field = h("01 58 24") <> body(h("01"), "slice 140")
    esp_protected = h("a3 01 38 32 04 58 30") <> ec_kid <> h("10 78 2b") <> @typ_esp
    esp = fn sig_field -> carrier.(esp_payload_field, h("84 58 65") <> esp_protected <> h("a0 f6") <> sig_field) end
    esp_sig = h(@esp_sig)
    <<r::binary-size(48), s::unsigned-size(384)>> = esp_sig
    n_minus_s = r <> <<@p384_n - s::unsigned-size(384)>>
    ec_kid_hex = Base.encode16(ec_kid, case: :lower)
    ed_kid_hex = Base.encode16(ed_kid, case: :lower)

    [
      {"ed25519_single", good, 0, "claim", "commercial", nil},
      {"ed25519_single_at_nss", good, 1, "alg_not_permitted", "nss", nil},
      {"ed25519_signature_flipped", carrier.(payload_field, ed_sign1.(flipped)), 1, "signature_invalid", "commercial", nil},
      {"ed25519_no_issuer", carrier.(no_issuer, ed_sign1.(h(@ed_sig))), 1, "issuer_missing", "commercial", nil},
      {"ed25519_typ_schema_mismatch", carrier.(schema_2, ed_sign1.(h(@ed_sig_schema_2))), 1, "typ_schema_mismatch", "commercial", nil},
      {"ed25519_key_registered_as_mldsa87", good, 1, "alg_not_permitted", "commercial",
       [%{"alg" => -50, "public" => "thumbprint/rfc8032_test1_ed25519.pub", "kid" => ed_kid_hex}]},
      {"carrier_key0_envelope", h("a3 00 1a ff ff 00 01") <> payload_field <> h("02") <> sign1, 1, "carrier_malformed", "commercial", nil},
      {"carrier_extra_key", h("a4 00") <> h(@single_schema) <> payload_field <> h("02") <> sign1 <> h("03 00"), 1, "carrier_malformed", "commercial", nil},
      {"carrier_no_sign1", h("a2 00") <> h(@single_schema) <> payload_field, 1, "carrier_malformed", "commercial", nil},
      {"carrier_payload_text", h("a3 00") <> h(@single_schema) <> h("01 69") <> "slice 139" <> h("02") <> sign1, 1, "carrier_malformed", "commercial", nil},
      {"carrier_not_map", h("83") <> h(@single_schema) <> h("58 24") <> payload <> sign1, 1, "carrier_malformed", "commercial", nil},
      {"carrier_keys_out_of_order", h("a3 00") <> h(@single_schema) <> h("02") <> sign1 <> payload_field, 1, "noncanonical", "commercial", nil},
      {"sign1_attached",
       carrier.(payload_field, h("84 58 65") <> protected <> h("a0 58 24") <> payload <> h("58 40") <> sig),
       1, "carrier_malformed", "commercial", nil},
      {"sign1_tagged", carrier.(payload_field, h("d2") <> sign1), 1, "tag_forbidden", "commercial", nil},
      {"sign1_unprotected_kid",
       carrier.(payload_field, h("84 58 65") <> protected <> h("a1 04 41 00 f6 58 40") <> sig),
       1, "header_not_protected", "commercial", nil},
      {"pair_typ_in_single_carrier", carrier.(payload_field, twin_sign1), 1, "wrong_carrier_for_typ", "commercial", nil},
      # Slice 140: ESP384 (-51), the publisher's Decision of 2026-10-20, point 1.
      {"esp384_single", esp.(h("58 60") <> esp_sig), 0, "claim", "commercial", nil},
      {"esp384_n_minus_s", esp.(h("58 60") <> n_minus_s), 0, "claim", "commercial", nil},
      {"esp384_at_nss", esp.(h("58 60") <> esp_sig), 1, "alg_not_permitted", "nss", nil},
      {"esp384_signature_der", esp.(h("58 67") <> h(@esp_der)), 1, "signature_encoding", "commercial", nil},
      {"esp384_signature_95_bytes", esp.(h("58 5f") <> binary_part(esp_sig, 0, 95)), 1, "signature_encoding", "commercial", nil},
      {"esp384_signature_97_bytes", esp.(h("58 61") <> esp_sig <> h("00")), 1, "signature_encoding", "commercial", nil},
      {"esp384_signature_flipped", esp.(h("58 60") <> binary_part(esp_sig, 0, 95) <> <<:binary.last(esp_sig) |> Bitwise.bxor(1)>>), 1, "signature_invalid", "commercial", nil},
      {"esp384_key_compressed", esp.(h("58 60") <> esp_sig), 1, "key_invalid", "commercial",
       [%{"alg" => -51, "public" => "thumbprint/rfc6979_a26_p384_compressed.pub", "kid" => ec_kid_hex}]},
      {"esp384_key_p256", esp.(h("58 60") <> esp_sig), 1, "key_invalid", "commercial",
       [%{"alg" => -51, "public" => "thumbprint/rfc6979_a25_p256.pub", "kid" => ec_kid_hex}]},
      {"esp384_key_registered_as_ed25519", esp.(h("58 60") <> esp_sig), 1, "alg_not_permitted", "commercial",
       [%{"alg" => -19, "public" => "thumbprint/rfc6979_a26_p384.pub", "kid" => ec_kid_hex}]}
    ]
  end

  # {0: key0, 1: "trinity:test.invalid", 16: text}, 36 bytes for a 9-byte text.
  defp body(key0, text), do: h("a3 00") <> key0 <> h("01 74") <> @issuer <> h("10 69") <> text

  defp ec2_kid(<<4, x::binary-size(48), y::binary-size(48)>>),
    do: :crypto.hash(:sha384, h("a4 01 02 20 02 21 58 30") <> x <> h("22 58 30") <> y)

  @default_keys [
    %{"alg" => -19, "public" => "thumbprint/rfc8032_test1_ed25519.pub"},
    %{"alg" => -50, "public" => "thumbprint/acvp_mldsa87_tg3_tc51.pub"},
    %{"alg" => -51, "public" => "thumbprint/rfc6979_a26_p384.pub"}
  ]

  defp sample(root, id, bytes, exit, code, entry, keys) do
    write(root, "cose/sign1/#{id}.bin", bytes)
    write(root, "cose/sign1/#{id}.expect", json(%{"exit" => exit, "verdict_code" => code, "source" => "hand"}))

    ctx = %{
      "entry_point" => entry,
      "typ_table" => "header/profile-table.json",
      "keys" => keys || @default_keys
    }

    write(root, "cose/sign1/#{id}.ctx.json", json(ctx))
  end

  ## Digest

  defp digest_negative do
    d32 = :binary.copy(<<0xAB>>, 32)
    d48 = :binary.copy(<<0xAB>>, 48)

    [
      {"digest_alg_not_permitted", "sha256", h("82 2f 58 20") <> d32, "digest_alg_not_permitted"},
      {"digest_alg_not_permitted", "shake256", h("82 38 2c 58 40") <> :binary.copy(<<0xAB>>, 64), "digest_alg_not_permitted"},
      {"digest_length_mismatch", "sha384_32_bytes", h("82 38 2a 58 20") <> d32, "digest_length_mismatch"},
      {"digest_not_array", "bstr", h("58 30") <> d48, "field_type_mismatch"}
    ]
  end

  ## Files

  defp positive(root, layer, id, bytes, desc, source) do
    write(root, "#{layer}/positive/#{id}.cbor", bytes)
    write(root, "#{layer}/positive/#{id}.desc.json", json(%{"value" => desc_json(desc), "source" => source}))
    write(root, "#{layer}/positive/#{id}.diag", diag(desc) <> "\n")
  end

  defp negative(root, layer, defect, id, bytes, code, source) do
    write(root, "#{layer}/negative/#{defect}/#{id}.cbor", bytes)

    write(
      root,
      "#{layer}/negative/#{defect}/#{id}.expect",
      json(%{"exit" => 1, "verdict_code" => code, "source" => source})
    )
  end

  defp desc_json({:i, n}), do: %{"i" => Integer.to_string(n)}
  defp desc_json({:b, b}), do: %{"b" => Base.encode16(b, case: :lower)}
  defp desc_json({:t, t}), do: %{"t" => Base.encode16(t, case: :lower)}
  defp desc_json({:s, s}), do: %{"s" => s}
  defp desc_json({:a, items}), do: %{"a" => Enum.map(items, &desc_json/1)}
  defp desc_json({:m, pairs}), do: %{"m" => Enum.map(pairs, fn {k, v} -> [desc_json(k), desc_json(v)] end)}

  # RFC 8949 section 8, for the subset: integers in decimal, h'..' byte strings, JSON-style text.
  defp diag({:i, n}), do: Integer.to_string(n)
  defp diag({:b, b}), do: "h'" <> Base.encode16(b, case: :lower) <> "'"
  defp diag({:t, t}), do: JSON.encode!(t)
  defp diag({:s, s}), do: s
  defp diag({:a, items}), do: "[" <> Enum.map_join(items, ", ", &diag/1) <> "]"
  defp diag({:m, pairs}), do: "{" <> Enum.map_join(pairs, ", ", fn {k, v} -> diag(k) <> ": " <> diag(v) end) <> "}"

  defp json(term), do: JSON.encode!(term) <> "\n"

  defp write(root, rel, bytes) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  # `sha384sum -c SHA384SUMS`, run in the vector directory, checks every other file. Lines are
  # "<lowercase hex><two spaces><path relative to the directory>", sorted by path bytewise, LF.
  defp write_sums(root) do
    lines =
      root
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(&1 == "SHA384SUMS"))
      |> Enum.sort()
      |> Enum.map(fn rel ->
        hex = :crypto.hash(:sha384, File.read!(Path.join(root, rel))) |> Base.encode16(case: :lower)
        hex <> "  " <> rel <> "\n"
      end)

    File.write!(Path.join(root, "SHA384SUMS"), lines)
  end

  defp h(hex), do: hex |> String.replace(" ", "") |> Base.decode16!(case: :lower)
end

N6Vectors.run(System.argv())
