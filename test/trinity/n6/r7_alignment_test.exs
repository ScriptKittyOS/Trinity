# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.R7AlignmentTest do
  # Slice 142: the codec and the code registry against N6 draft v0.1-r7.
  use ExUnit.Case, async: true

  alias Trinity.N6.{CBOR, Profile, Unicode15}

  defp text(s), do: <<0x60 + byte_size(s)>> <> s

  describe "AC1: the text rule" do
    test "format controls are refused, the neighbouring code points are not" do
      for cp <- [0x200B, 0x202E, 0xFEFF, 0x00AD, 0x200D, 0x2066, 0xE0041] do
        assert {:error, :text_format_control, 0} = CBOR.decode(text(<<cp::utf8>>)),
               "U+#{Integer.to_string(cp, 16)}"

        assert CBOR.encode({:text, <<cp::utf8>>}) == {:error, :text_format_control}
      end

      for cp <- [0x200A, 0x2010, 0x00AC, 0x2056] do
        assert {:ok, {:text, _}} = CBOR.decode(text(<<cp::utf8>>)),
               "U+#{Integer.to_string(cp, 16)}"
      end
    end

    test "a code point assigned only from Unicode 16.0 is unassigned, whatever the runtime says" do
      # U+1C89, CYRILLIC CAPITAL LETTER TJE, is new in 16.0: the runtime's own data calls it a
      # letter, the pinned 15.0.0 tables do not, and the tables decide.
      assert String.match?("Ᲊ", ~r/\p{L}/u)
      assert {:error, :text_unassigned, 0} = CBOR.decode(text("Ᲊ"))
      assert {:error, :text_unassigned, 0} = CBOR.decode(text(<<0xFFFE::utf8>>))
    end

    test "the quick check: Maybe is nfc_maybe, a combining class out of order is not_nfc" do
      assert {:error, :nfc_maybe, 0} = CBOR.decode(text("é"))
      assert {:error, :nfc_maybe, 0} = CBOR.decode(text("क़"))

      # U+0591 (class 220) then U+05B0 (class 10): both NFC_QC Yes, so only the order refuses it.
      assert {Unicode15.nfc_qc(0x0591), Unicode15.nfc_qc(0x05B0)} == {:yes, :yes}
      assert {:error, :not_nfc, 0} = CBOR.decode(text("ְ֑"))
      assert {:ok, _} = CBOR.decode(text("ְ֑"))
    end

    test "UTF-8 is checked over the whole string before the text rule starts" do
      assert {:error, :invalid_utf8, 0} = CBOR.decode(text(<<"​", 0xFF>>))
    end
  end

  describe "AC2: the tables" do
    test "the counts draft v0.1-r7 states" do
      assert Unicode15.version() == "15.0.0"

      assert %{cn: 825_345, cf: 170, qc_no: 1120, qc_maybe: 111} =
               Unicode15.counts()
    end

    test "no Unicode normaliser is called anywhere in the N6 code" do
      offenders =
        for path <- Path.wildcard("lib/trinity/n6/**/*.ex"),
            source = File.read!(path),
            Regex.match?(~r/characters_to_nf[ck]|String\.normalize|:unicode_util/, source),
            do: path

      assert offenders == []
    end

    @ucd System.get_env("TRINITY_UCD_DIR")
    @tag :tmp_dir
    if @ucd do
      test "the generator writes the checked-in module byte for byte", %{tmp_dir: tmp} do
        out = Path.join(tmp, "unicode15.ex")
        {_, 0} = System.cmd("elixir", ["scripts/unicode15_tables.exs", @ucd, out])
        assert File.read!(out) == File.read!("lib/trinity/n6/unicode15.ex")
      end
    else
      @tag skip: "set TRINITY_UCD_DIR to the Unicode 15.0.0 data files to run this"
      test "the generator writes the checked-in module byte for byte" do
      end
    end
  end

  describe "AC3: a key's head is checked before its type" do
    test "indefinite, not well-formed and truncated key heads keep their own codes" do
      assert {:error, :indefinite_length, 1} = CBOR.decode(<<0xA1, 0x7F, 0xFF, 0x00>>)
      assert {:error, :not_well_formed, 1} = CBOR.decode(<<0xA1, 0x1C, 0x00>>)
      assert {:error, :truncated, 1} = CBOR.decode(<<0xA1, 0x19, 0x00>>)
      assert {:error, :key_not_uint, 1} = CBOR.decode(<<0xA1, 0x61, ?a, 0x00>>)
    end
  end

  describe "AC4: the registry" do
    # Draft v0.1-r7 section 9.4, every code a conforming implementation may emit.
    @r7 ~w(claim verified_nonclaimed too_large truncated not_well_formed indefinite_length
           key_not_uint tag_forbidden float_forbidden simple_forbidden noncanonical duplicate_key
           int_out_of_range too_deep too_many_items text_too_long invalid_utf8 text_unassigned
           not_nfc text_format_control nfc_maybe trailing_bytes body_not_map schema_version_missing
           schema_reserved test_schema_outside_test_mode unknown_schema typ_schema_mismatch
           issuer_missing field_missing unknown_key field_type_mismatch value_out_of_range
           text_grammar_mismatch set_not_canonical digest_alg_not_permitted digest_length_mismatch
           header_noncanonical header_label_forbidden header_missing typ_unexpected
           wrong_carrier_for_typ content_type_forbidden header_value_invalid alg_not_permitted
           key_invalid kid_not_thumbprint carrier_malformed note_malformed header_not_protected
           unprotected_forbidden countersignature_forbidden signature_encoding signature_invalid
           signature_invalid_kv signature_invalid_kh no_trusted_signature duplicate_line
           duplicate_signer signer_order pair_mismatch twin_header_mismatch class_mismatch
           partial_refused key_retired window_reopened foreign_digest_mismatch usage
           policy_stale_or_unknown_key unknown_origin descriptor_unverified foreign_bytes_missing
           degraded_kv_only degraded_kh_only fork_kv fork_kh fork_pair epoch_regression
           key_revoked_compromised_kv key_revoked_compromised_kh issuer_mismatch_kh
           accuse_kv_issuer_mismatch accuse_foreign_origin_signed_kv accuse_logged_nonconforming
           accuse_single_signed_noncanonical accuse_single_signed_nonconforming)a

    test "every draft code is in r7's registry, with r7's exit class; only two are this tree's" do
      for {code, {exit, :draft, _steps}} <- Profile.codes() do
        assert code in @r7, "#{code} is marked :draft but is not in r7 section 9.4"

        expected =
          if String.starts_with?(Atom.to_string(code), "accuse_"), do: [7], else: [0, 1, 2, 5]

        assert exit in expected, "#{code}"
      end

      ours = for {code, {_exit, :trinity, _steps}} <- Profile.codes(), do: code
      assert Enum.sort(ours) == [:alg_unavailable, :value_not_n6]
    end

    test "the pin names v0.1-r7" do
      assert %{version: "n6/v0.1", draft: "v0.1-r7"} = Profile.pin()
    end
  end
end
