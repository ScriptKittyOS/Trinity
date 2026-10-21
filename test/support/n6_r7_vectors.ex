# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestSupport.N6R7Vectors do
  @moduledoc """
  Reads a vector set in the layout of N6 draft v0.1-r7 section 10 (slice 142), and holds the test
  profile of its section 10.3: the test schemas in block 0x80, their `typ` values and the three
  test entry points. Every judgment goes through `Trinity.N6`, so a run is the codec's answer, not
  this module's.

  `run/1` judges every vector of the five cut directories (encoding, body, header, thumbprint,
  digest) and answers, per directory, the vectors that agree and the ones that do not.
  """

  alias Trinity.N6.{Body, CBOR, COSE, Digest}

  @issuer {:one_of, [{:tstr, 1, 255, :printable_ascii}, {:bstr, 1, 64}]}

  @test_body_fields %{
    1 => {:issuer, @issuer, :required},
    6 => {:id, {:bstr, 16, 32}, :optional},
    7 => {:prev, :digest, :optional},
    16 => {:count, {:int, 0, 1000}, :optional},
    17 => {:level, {:enum, 3, true}, :optional},
    18 => {:delta, {:int, -100, 100}, :optional},
    19 => {:note, {:tstr, 0, 256, :any}, :optional},
    20 => {:tags, {:set, {:int, 0, 0xFFFF_FFFF}}, :optional},
    21 => {:blob, :bstr, :optional},
    22 => {:cleared, {:nullable, :uint}, :optional},
    23 => {:ref, :foreign_ref, :optional},
    24 =>
      {:pair,
       {:map,
        %{1 => {:a, :uint, :required}, 2 => {:b, {:tstr, 1, 64, :printable_ascii}, :optional}}},
       :optional},
    25 => {:flag, :bool, :optional}
  }

  @test_pair_fields %{
    1 => {:issuer, @issuer, :required},
    9 => {:signer_ctr, {:tuple, [{:int, 0, 0xFFFF_FFFF}, :uint, :uint]}, :required},
    10 => {:key_policy, :digest, :required}
  }

  @typ_body "application/vnd.example.b80.test_body.v0+cose"
  @typ_pair "application/vnd.example.b80.test_pair.v0+cose"
  @typ_hash "application/vnd.example.b80.test_hash.v0+cose"
  @typ_scitt "application/vnd.example.b80.test_scitt.v0+cose"

  @doc "The test schemas of r7 section 10.3."
  def schemas do
    [
      %{kind: "test_body", version: 0x8000_0101, typ: @typ_body, fields: @test_body_fields},
      %{kind: "test_pair", version: 0x8000_0201, typ: @typ_pair, fields: @test_pair_fields},
      %{kind: "test_scitt", version: 0x8000_0401, typ: @typ_scitt, fields: @test_body_fields}
    ]
  end

  @doc "The test profile table: every `typ` of r7 section 10.3."
  def typ_table do
    %{
      @typ_body => %{scitt: false, carrier: :single, signers: :single, schema: 0x8000_0101},
      @typ_pair => %{scitt: false, carrier: :envelope, signers: :pair, schema: 0x8000_0201},
      @typ_hash => %{scitt: false, carrier: :single, signers: :single, form: :hash},
      @typ_scitt => %{scitt: true, carrier: :single, signers: :single, schema: 0x8000_0401}
    }
  end

  @doc "The three test entry points."
  def entry_points do
    %{
      "test.nss.single" => %{algs: [-50], typs: [@typ_body, @typ_scitt, @typ_hash]},
      "test.commercial.ed25519.single" => %{algs: [-19], typs: [@typ_body]},
      "test.commercial.es384.single" => %{algs: [-51], typs: [@typ_body]}
    }
  end

  @doc "`VERSION`'s first line, and the SHA-384 of `SHA384SUMS` (r7 section 11)."
  def pin(root) do
    [version | _] = root |> Path.join("VERSION") |> File.read!() |> String.split("\n")
    sums = root |> Path.join("SHA384SUMS") |> File.read!()
    {version, :crypto.hash(:sha384, sums) |> Base.encode16(case: :lower)}
  end

  @doc "Every file `SHA384SUMS` lists whose digest does not match, and every file it does not list."
  def sums_defects(root) do
    listed =
      root
      |> Path.join("SHA384SUMS")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [hex, path] = String.split(line, "  ", parts: 2)
        {path, hex}
      end)

    on_disk =
      for path <- Path.wildcard(Path.join(root, "**/*")),
          File.regular?(path),
          rel = Path.relative_to(path, root),
          rel != "SHA384SUMS",
          do: rel

    wrong =
      for {rel, hex} <- listed,
          :crypto.hash(:sha384, File.read!(Path.join(root, rel))) |> Base.encode16(case: :lower) !=
            hex,
          do: {:digest, rel}

    wrong ++ for(rel <- on_disk, not is_map_key(listed, rel), do: {:unlisted, rel})
  end

  @doc "Judges every vector of the cut directories: `%{dir => {agree, [disagreement]}}`."
  def run(root) do
    Map.new(~w(encoding body header thumbprint digest), fn dir ->
      results = judge(dir, Path.join(root, dir))
      wrong = for {id, want, got} <- results, want != got, do: {id, want, got}
      {dir, {length(results) - length(wrong), wrong}}
    end)
  end

  defp judge("encoding", dir) do
    positives(dir, fn base, ctx ->
      bytes = File.read!(base <> ".cbor")
      value = base |> Kernel.<>(".desc.json") |> File.read!() |> JSON.decode!() |> value()
      ok?(CBOR.encode(value) == {:ok, bytes} and CBOR.decode(bytes) == {:ok, value}, ctx)
    end) ++ negatives(dir, &code(CBOR.decode(File.read!(&1 <> ".cbor"))))
  end

  defp judge("body", dir) do
    body = fn base ->
      ctx = ctx(base)
      opts = [test_mode: Map.get(ctx, "test_mode", false), typ: Map.get(ctx, "typ")]
      code(Body.decode(File.read!(base <> ".cbor"), :any, schemas(), opts))
    end

    positives(dir, fn base, _ctx -> body.(base) end) ++ negatives(dir, body)
  end

  defp judge("header", dir) do
    header = fn base ->
      entry = Map.fetch!(entry_points(), Map.fetch!(ctx(base), "entry"))
      code(COSE.decode_protected(File.read!(base <> ".cbor"), typ_table(), entry))
    end

    positives(dir, fn base, _ctx -> header.(base) end) ++ negatives(dir, header)
  end

  defp judge("thumbprint", dir) do
    positives =
      for meta <- Path.wildcard(Path.join(dir, "*.meta.json")) |> Enum.sort() do
        base = String.replace_suffix(meta, ".meta.json", "")
        {kty, crv, alg, pub} = key(base)

        got =
          with :ok <- COSE.check_key(kty, crv, alg, pub) do
            kid = File.read!(base <> ".kid")
            input = File.read!(base <> ".input")

            ok?(COSE.thumbprint(alg, pub) == kid and :crypto.hash(:sha384, input) == kid, nil)
          end

        {Path.basename(base), :ok, got}
      end

    positives ++
      negatives(dir, fn base ->
        {kty, crv, alg, pub} = key(base)
        COSE.check_key(kty, crv, alg, pub)
      end)
  end

  defp judge("digest", dir) do
    positives =
      for meta <- Path.wildcard(Path.join(dir, "*.meta.json")) |> Enum.sort() do
        base = String.replace_suffix(meta, ".meta.json", "")
        m = meta |> File.read!() |> JSON.decode!()
        ref = Digest.foreign_ref(File.read!(base <> ".in"), m["media_type"], m["locator"])
        {Path.basename(base), :ok, ok?(CBOR.encode!(ref) == File.read!(base <> ".ref.cbor"), nil)}
      end

    positives ++
      negatives(dir, fn base ->
        attached = if File.exists?(base <> ".in"), do: File.read!(base <> ".in")

        with {:ok, ref} <- CBOR.decode(File.read!(base <> ".ref.cbor")) |> code(),
             :ok <- Body.check_value(ref, :foreign_ref) do
          Digest.attachment(ref, attached)
        end
      end)
  end

  defp positives(dir, fun) do
    for desc <- Path.wildcard(Path.join([dir, "positive", "*.cbor"])) |> Enum.sort() do
      base = String.replace_suffix(desc, ".cbor", "")
      {"positive/" <> Path.basename(base), :ok, fun.(base, nil) |> ok_only()}
    end
  end

  defp negatives(dir, fun) do
    for expect <- Path.wildcard(Path.join([dir, "negative", "*", "*.expect"])) |> Enum.sort() do
      base = String.replace_suffix(expect, ".expect", "")
      id = Path.relative_to(base, Path.join(dir, "negative"))
      {id, expected(expect), fun.(base) |> ok_only()}
    end
  end

  defp expected(path) do
    lines = path |> File.read!() |> String.split("\n", trim: true)
    ["exit " <> exit, "verdict_code: " <> code | _] = lines
    {:error, String.to_integer(exit), String.to_atom(code)}
  end

  # A judgment as `{:error, exit, code}` against the expectation, or `:ok`.
  defp ok_only({:ok, _}), do: :ok
  defp ok_only({:ok, _, _}), do: :ok
  defp ok_only(:ok), do: :ok
  defp ok_only({:error, code}), do: {:error, Trinity.N6.Profile.exit_of(code), code}
  defp ok_only({:error, code, _offset}), do: {:error, Trinity.N6.Profile.exit_of(code), code}
  defp ok_only(other), do: other

  defp code({:error, code, _offset}), do: {:error, code}
  defp code(other), do: other

  defp ok?(true, _ctx), do: :ok
  defp ok?(false, _ctx), do: {:error, :mismatch}

  defp ctx(base) do
    path = base <> ".ctx.json"
    if File.exists?(path), do: path |> File.read!() |> JSON.decode!(), else: %{}
  end

  defp key(base) do
    m = (base <> ".meta.json") |> File.read!() |> JSON.decode!()
    kty = %{"AKP" => :akp, "EC2" => :ec2, "OKP" => :okp} |> Map.fetch!(m["kty"])
    crv = if m["crv"], do: String.to_integer(m["crv"])
    {kty, crv, String.to_integer(m["alg"]), File.read!(base <> ".pub")}
  end

  @doc "The value a `desc.json` node stands for (r7 section 10.2)."
  def value(%{"i" => n}), do: String.to_integer(n)
  def value(%{"b" => hex}), do: {:bytes, Base.decode16!(hex, case: :lower)}
  def value(%{"t" => hex}), do: {:text, Base.decode16!(hex, case: :lower)}
  def value(%{"s" => "true"}), do: true
  def value(%{"s" => "false"}), do: false
  def value(%{"s" => "null"}), do: nil
  def value(%{"a" => items}), do: Enum.map(items, &value/1)
  def value(%{"m" => pairs}), do: Map.new(pairs, fn [k, v] -> {value(k), value(v)} end)
end
