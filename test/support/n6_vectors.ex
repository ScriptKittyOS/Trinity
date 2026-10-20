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
      {defect, id, bytes, String.to_existing_atom(code)}
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
    |> Map.new(&{&1["typ"], %{scitt: &1["scitt"]}})
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
