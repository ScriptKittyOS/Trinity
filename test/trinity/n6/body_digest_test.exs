# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.BodyDigestTest do
  @moduledoc """
  Slice 138, AC4 and AC5: the body rules under the vectors' test schema, and digests of foreign
  bytes. Both read their populations from `test/fixtures/n6/`.
  """

  use ExUnit.Case, async: true

  alias Trinity.N6.{Body, CBOR, Digest, Profile}
  alias Trinity.TestSupport.N6Vectors

  @kind "trinity.test"

  setup_all do
    %{schemas: [N6Vectors.body_schema()]}
  end

  describe "AC4: the body rules" do
    test "every positive body decodes under its schema", %{schemas: schemas} do
      vectors = N6Vectors.positive("body")
      assert vectors != []

      for {id, bytes, value} <- vectors do
        assert {:ok, ^value, %{version: 1}} = Body.decode(bytes, @kind, schemas), id
        assert Body.encode(value, @kind, schemas) == {:ok, bytes}, id
      end
    end

    test "every negative body is refused with its code", %{schemas: schemas} do
      vectors = N6Vectors.negative("body")
      assert length(vectors) >= 12

      for {defect, id, bytes, code} <- vectors do
        assert {:error, ^code, _} = Body.decode(bytes, @kind, schemas), "#{defect}/#{id}"
        assert Profile.exit_of(code) == 1
      end
    end

    test "the encoder refuses a body the decoder would refuse", %{schemas: schemas} do
      assert Body.encode(%{16 => {:text, "x"}}, @kind, schemas) ==
               {:error, :schema_version_missing}

      assert Body.encode(%{0 => 1, 16 => {:text, "x"}, 18 => [2, 1]}, @kind, schemas) ==
               {:error, :set_not_canonical}

      assert Body.encode(%{0 => 1, 16 => {:text, "x"}, 99 => 0}, @kind, schemas) ==
               {:error, :unknown_key}
    end

    test "a nested map is checked against its own fields, key 0 included" do
      schemas = [
        %{
          kind: "k",
          version: 1,
          fields: %{16 => {:inner, {:map, %{1 => {:a, :uint, :required}}}, :required}}
        }
      ]

      assert {:ok, _} = Body.check(%{0 => 1, 16 => %{1 => 5}}, "k", schemas)

      assert Body.check(%{0 => 1, 16 => %{0 => 0, 1 => 5}}, "k", schemas) ==
               {:error, :unknown_key}

      assert Body.check(%{0 => 1, 16 => %{}}, "k", schemas) == {:error, :field_missing}
    end

    test "a schema version in the reserved carrier range is refused even when a schema claims it" do
      schemas = [%{kind: @kind, version: 0xFFFF_0001, fields: %{}}]
      assert Body.check(%{0 => 0xFFFF_0001}, @kind, schemas) == {:error, :schema_reserved}
    end
  end

  describe "AC5: digests of foreign bytes" do
    test "the vector: SHA-384 over the bytes exactly as given, and their exact length" do
      raw = File.read!(Path.join(N6Vectors.root(), "digest/abc.in"))
      expected = File.read!(Path.join(N6Vectors.root(), "digest/abc.ref.cbor"))

      ref = Digest.foreign_ref(raw, "application/octet-stream")
      assert CBOR.encode!(ref) == expected
      assert %{0 => digest, 1 => 3} = ref
      assert Digest.check(digest) == :ok
      assert Digest.matches?(digest, raw)
      refute Digest.matches?(digest, raw <> "\n")
    end

    test "every negative digest is refused with its code" do
      vectors = N6Vectors.negative("digest")
      assert length(vectors) >= 4

      for {defect, id, bytes, code} <- vectors do
        assert {:ok, value} = CBOR.decode(bytes), "#{defect}/#{id} must be valid CBOR"
        assert Digest.check(value) == {:error, code}, "#{defect}/#{id}"
      end
    end

    test "SHA-512 is refused until the profile decides it" do
      assert Digest.check([-44, {:bytes, :binary.copy(<<0>>, 64)}]) ==
               {:error, :digest_alg_not_permitted}
    end
  end
end
