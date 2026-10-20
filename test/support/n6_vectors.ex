# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestSupport.N6Vectors do
  @moduledoc """
  Reads Trinity's provisional N6 vectors (`test/fixtures/n6/`, written by
  `scripts/n6_vectors.exs`; slice 138). The populations every N6 test iterates are listed from
  the directory, never typed, so a vector added to the set is tested without a test changing.
  """

  @root "test/fixtures/n6"

  @doc "The vector directory."
  def root, do: @root

  @doc "`{id, bytes, value}` for each positive vector of a layer."
  def positive(layer) do
    for desc_path <-
          Path.wildcard(Path.join([@root, layer, "positive", "*.desc.json"])) |> Enum.sort() do
      id = Path.basename(desc_path, ".desc.json")
      bytes = File.read!(Path.join([@root, layer, "positive", id <> ".cbor"]))
      %{"value" => desc} = desc_path |> File.read!() |> JSON.decode!()
      {id, bytes, value(desc)}
    end
  end

  @doc "`{defect, id, bytes, code}` for each negative vector of a layer."
  def negative(layer) do
    for expect_path <-
          Path.wildcard(Path.join([@root, layer, "negative", "*", "*.expect"])) |> Enum.sort() do
      defect = expect_path |> Path.dirname() |> Path.basename()
      id = Path.basename(expect_path, ".expect")
      bytes = File.read!(Path.rootname(expect_path) <> ".cbor")
      %{"exit" => 1, "verdict_code" => code} = expect_path |> File.read!() |> JSON.decode!()
      # `to_atom`, as in `samples/0`: under seed 789020 the body test asked for `:key_not_uint`
      # before any module defining it was loaded (postgres job, PR #135).
      {defect, id, bytes, String.to_atom(code)}
    end
  end

  @doc "The value a vector description stands for (integers are decimal strings, so above 2^53 survive JSON)."
  def value(%{"i" => n}), do: String.to_integer(n)
  def value(%{"b" => hex}), do: {:bytes, Base.decode16!(hex, case: :lower)}
  def value(%{"t" => hex}), do: {:text, Base.decode16!(hex, case: :lower)}
  def value(%{"s" => "true"}), do: true
  def value(%{"s" => "false"}), do: false
  def value(%{"s" => "null"}), do: nil
  def value(%{"a" => items}), do: Enum.map(items, &value/1)
  def value(%{"m" => pairs}), do: Map.new(pairs, fn [k, v] -> {value(k), value(v)} end)

  @doc "The body vectors' test schema, as `Trinity.N6.Body` takes it."
  def body_schema do
    s = Path.join([@root, "body", "schema.json"]) |> File.read!() |> JSON.decode!()

    fields =
      Map.new(s["fields"], fn f ->
        type =
          case f["type"] do
            "tstr" -> :tstr
            "uint" -> :uint
            "set of uint" -> {:set, :uint}
          end

        {f["key"],
         {String.to_atom(f["name"]), type, if(f["required"], do: :required, else: :optional)}}
      end)

    %{kind: s["kind"], version: s["schema_version"], fields: fields}
  end

  @doc "The header vectors' `typ` table, as `Trinity.N6.COSE` takes it."
  def typ_table do
    Path.join([@root, "header", "profile-table.json"])
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("typ")
    |> Map.new(fn e ->
      {e["typ"],
       %{
         scitt: e["scitt"],
         alg: e["alg"],
         carrier: String.to_atom(e["carrier"]),
         signers: String.to_atom(e["signers"])
       }}
    end)
  end

  @doc """
  The single-signer carrier samples (slice 139): `{id, bytes, exit, code, opts}`, where `opts` is
  what `Trinity.N6.Carrier.verify/2` takes, read from the sample's `.ctx.json`.
  """
  def samples do
    for bin <- Path.wildcard(Path.join([@root, "cose", "sign1", "*.bin"])) |> Enum.sort() do
      id = Path.basename(bin, ".bin")
      base = Path.rootname(bin)

      %{"exit" => exit, "verdict_code" => code} =
        (base <> ".expect") |> File.read!() |> JSON.decode!()

      ctx = (base <> ".ctx.json") |> File.read!() |> JSON.decode!()

      registered =
        Map.new(ctx["keys"], fn %{"alg" => alg, "public" => rel} ->
          pub = File.read!(Path.join(@root, rel))
          {thumbprint(alg, pub), %{alg: alg, public: pub}}
        end)

      opts = [
        keys: &Map.fetch(registered, &1),
        typ: typ_table(),
        entry: String.to_atom(ctx["entry_point"])
      ]

      # `to_atom`, not `to_existing_atom`: which atoms exist depends on which modules a test run has
      # loaded first, and these strings come from the checked-in fixtures, not from input.
      {id, File.read!(bin), exit, String.to_atom(code), opts}
    end
  end

  # RFC 9679 over the AKP (RFC 9964 section 6) or OKP (RFC 9053 section 7.1) members, built here
  # from the fixed prefixes rather than asked of `Trinity.N6.COSE`, the code under test.
  defp thumbprint(-50, pub),
    do: :crypto.hash(:sha384, <<0xA3, 1, 7, 3, 0x38, 0x31, 0x20, 0x59, 0x0A, 0x20>> <> pub)

  defp thumbprint(-19, pub),
    do: :crypto.hash(:sha384, <<0xA3, 1, 1, 0x20, 6, 0x21, 0x58, 0x20>> <> pub)

  @doc "RFC 8032 section 7.1, test 1: the published Ed25519 key."
  def rfc8032_key do
    %{
      alg: -19,
      public:
        Base.decode16!("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
          case: :lower
        ),
      private:
        Base.decode16!("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
          case: :lower
        )
    }
  end

  @doc "NIST ACVP's ML-DSA-87 keyGen case (slice 137 pins it): seed, public key, expanded secret key."
  def acvp_key do
    k = "priv/kat/acvp/mldsa87_keygen.json" |> File.read!() |> JSON.decode!()

    %{
      seed: Base.decode16!(k["seed"]),
      public: Base.decode16!(k["pk"]),
      expanded: Base.decode16!(k["sk"])
    }
  end
end
