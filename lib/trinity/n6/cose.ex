# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.COSE do
  @moduledoc """
  COSE_Sign1 under the N6 profile (its section 5; slice 138): ML-DSA-87 only, the header rules,
  the key thumbprint, signing and verifying.

  ## The protected header

      {1: -50, 4: kid, 16: typ, ? 15: {1: iss, 2: sub}}

  `alg` -50 is ML-DSA-87 (RFC 9964), pure, with an empty context string (RFC 9964 section 5).
  `kid` is the RFC 9679 COSE Key Thumbprint, SHA-384, over the AKP members RFC 9964 section 6
  names: `{1: 7, 3: -50, -1: pub}`, encoded under RFC 8949 section 4.2.1, which for a 2,592-byte key
  is exactly `a3 01 07 03 38 31 20 59 0a 20` followed by the key. The thumbprint includes `alg`, so a
  key cannot be used with another algorithm. `typ` (RFC 9596) is a media type, compared byte for
  byte against the table the caller passes; CWT claims (label 15) are present exactly when the
  table marks the `typ` as SCITT-renderable.

  The protected label set is closed to {1, 4, 15, 16}: content type (3) is refused with its own
  code, and every other label, `crit` (2) and the hash-envelope labels (258 to 260) among them,
  with `header_label_forbidden`. The header is strictly decoded (`Trinity.N6.CBOR`); a key that is
  not an unsigned integer is `header_label_forbidden` and every other encoding defect
  `header_noncanonical` (this tree's reading of the profile's W7).

  ## What is signed

  `ToBeSigned` is RFC 9052 section 4.4's `["Signature1", protected, h'', payload]`, with the
  protected bytes exactly as built or received and external_aad always empty. RFC 9052 signs the
  full payload "independent of how it is transported", so the signature does not depend on
  whether the payload travels attached or detached, or on tag 18.

  A COSE_Sign1 is held as its three parts (`t:parts/0`). `render/2` gives either exchange form:
  `:detached`, untagged with a nil payload, which is how the profile's carriers hold one, or
  `:attached_tagged`, `#6.18` with the payload inside. Which form a single-signer statement
  travels in is Open in the profile (its section 12.1 item 1), so neither is called the profile's.

  ## Verification outcomes

  `verify/2` answers the profile's exit classes: 0 with `:claim`, 1 (invalid) with the code of the
  rule that failed, or 5 (no trust) when the key is unknown (`policy_stale_or_unknown_key`) or the
  runtime cannot run ML-DSA-87 at all (`alg_unavailable`, this tree's code). A runtime that refuses
  the algorithm is never a crash and never a pass. The attribution classes 6 and 7 need the
  profile's key descriptors and are not decided here.

  ## Keys

  The private key is the 32-byte seed RFC 9964 section 4 defines, as `{:seed, seed}`, or the
  expanded key OTP's `generate_key/2` returns. The public key is passed beside it: on OTP 28.5.0.8
  no form of `:crypto.generate_key/3` derives it from a seed.
  """

  alias Trinity.N6.{CBOR, Profile}

  @alg -50
  @pub_size 2592
  @sig_size 4627
  @thumbprint_prefix <<0xA3, 0x01, 0x07, 0x03, 0x38, 0x31, 0x20, 0x59, 0x0A, 0x20>>
  @labels [1, 4, 15, 16]
  @required [1, 4, 16]
  @countersignature [7, 9, 11, 12]
  @tag18 0xD2

  @typedoc "One COSE_Sign1: the protected header bytes, the payload, the signature."
  @type parts :: %{protected: binary(), payload: binary(), signature: binary()}

  @typedoc "The `typ` values an entry point accepts, each saying whether it is SCITT-renderable."
  @type typ_table :: %{optional(String.t()) => %{scitt: boolean()}}

  @typedoc "An ML-DSA-87 key: the public key and the private key as a seed or expanded."
  @type key :: %{public: binary(), private: {:seed, binary()} | binary()}

  @doc "The RFC 9679 SHA-384 thumbprint of an ML-DSA-87 public key: its `kid`."
  @spec thumbprint(binary()) :: binary()
  def thumbprint(pub) when byte_size(pub) == @pub_size,
    do: :crypto.hash(:sha384, @thumbprint_prefix <> pub)

  @doc "The protected header bytes for a `kid` and `typ`, with CWT `{iss, sub}` when given."
  @spec protected_header(binary(), String.t(), {String.t(), String.t()} | nil) :: binary()
  def protected_header(kid, typ, cwt \\ nil) when byte_size(kid) == 48 and is_binary(typ) do
    header = %{1 => @alg, 4 => {:bytes, kid}, 16 => {:text, typ}}

    header =
      case cwt do
        {iss, sub} -> Map.put(header, 15, %{1 => {:text, iss}, 2 => {:text, sub}})
        nil -> header
      end

    CBOR.encode!(header)
  end

  @doc "Strictly decodes protected header bytes under the header rules and a `typ` table."
  @spec decode_protected(binary(), typ_table()) ::
          {:ok, %{kid: binary(), typ: String.t(), cwt: map() | nil}} | {:error, Profile.code()}
  def decode_protected(bytes, table) when is_binary(bytes) and is_map(table) do
    with {:ok, header} <- decode_header_map(bytes),
         :ok <- labels(header),
         :ok <- present(header),
         :ok <- alg(header),
         {:ok, kid} <- kid(header),
         {:ok, typ, entry} <- typ(header, table),
         {:ok, cwt} <- cwt(header, entry) do
      {:ok, %{kid: kid, typ: typ, cwt: cwt}}
    end
  end

  defp decode_header_map(bytes) do
    case CBOR.decode(bytes) do
      {:ok, header} when is_map(header) -> {:ok, header}
      {:ok, _other} -> {:error, :header_noncanonical}
      {:error, :key_not_uint, _} -> {:error, :header_label_forbidden}
      {:error, _code, _} -> {:error, :header_noncanonical}
    end
  end

  defp labels(header) do
    case header |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in @labels)) do
      nil -> :ok
      3 -> {:error, :content_type_forbidden}
      _label -> {:error, :header_label_forbidden}
    end
  end

  defp present(header) do
    if Enum.all?(@required, &is_map_key(header, &1)),
      do: :ok,
      else: {:error, :header_not_protected}
  end

  defp alg(%{1 => @alg}), do: :ok
  defp alg(_header), do: {:error, :alg_not_permitted}

  defp kid(%{4 => {:bytes, kid}}) when byte_size(kid) == 48, do: {:ok, kid}
  defp kid(_header), do: {:error, :kid_not_thumbprint}

  defp typ(%{16 => {:text, typ}}, table) do
    case Map.fetch(table, typ) do
      {:ok, entry} -> {:ok, typ, entry}
      :error -> {:error, :typ_unexpected}
    end
  end

  defp typ(_header, _table), do: {:error, :typ_unexpected}

  defp cwt(header, %{scitt: true}) do
    case Map.fetch(header, 15) do
      {:ok, %{1 => {:text, iss}, 2 => {:text, sub}} = claims} when map_size(claims) == 2 ->
        {:ok, %{iss: iss, sub: sub}}

      {:ok, _other} ->
        {:error, :header_label_forbidden}

      :error ->
        {:error, :header_not_protected}
    end
  end

  defp cwt(header, _entry) do
    if is_map_key(header, 15), do: {:error, :header_label_forbidden}, else: {:ok, nil}
  end

  @doc "RFC 9052 section 4.4's ToBeSigned for a Sign1, external_aad empty."
  @spec to_be_signed(binary(), binary()) :: binary()
  def to_be_signed(protected, payload) when is_binary(protected) and is_binary(payload),
    do:
      CBOR.encode!([{:text, "Signature1"}, {:bytes, protected}, {:bytes, ""}, {:bytes, payload}])

  @doc """
  Signs a payload as a Sign1 with ML-DSA-87. `opts`: `cwt: {iss, sub}` for a SCITT-renderable
  `typ`. Answers `{:error, :alg_unavailable}` where the runtime cannot sign ML-DSA-87.
  """
  @spec sign(binary(), String.t(), key(), keyword()) :: {:ok, parts()} | {:error, Profile.code()}
  def sign(payload, typ, %{public: pub, private: priv}, opts \\ [])
      when is_binary(payload) and byte_size(pub) == @pub_size and
             ((is_binary(priv) and byte_size(priv) == 4896) or
                (is_tuple(priv) and tuple_size(priv) == 2 and elem(priv, 0) == :seed and
                   byte_size(elem(priv, 1)) == 32)) do
    protected = protected_header(thumbprint(pub), typ, Keyword.get(opts, :cwt))
    signature = :crypto.sign(:mldsa87, :none, to_be_signed(protected, payload), priv)
    {:ok, %{protected: protected, payload: payload, signature: signature}}
  rescue
    e in ErlangError -> unavailable(e)
  end

  @doc """
  Verifies a Sign1's parts. `opts`: `keys`, a function from a `kid` to `{:ok, public_key}` or
  `:error`; `typ`, the `typ` table of the entry point in use.
  """
  @spec verify(parts(), keyword()) ::
          {:ok, %{exit: 0, verdict_code: :claim, kid: binary(), typ: String.t()}}
          | {:error, 1 | 5, Profile.code()}
  def verify(%{protected: protected, payload: payload, signature: signature}, opts)
      when is_binary(protected) and is_binary(payload) and is_binary(signature) do
    keys = Keyword.fetch!(opts, :keys)
    table = Keyword.fetch!(opts, :typ)

    with {:ok, %{kid: kid, typ: typ}} <- decode_protected(protected, table),
         {:ok, pub} <- known_key(keys.(kid)),
         :ok <- thumbprint_matches(pub, kid),
         :ok <- signature_size(signature),
         :ok <- signature_valid(to_be_signed(protected, payload), signature, pub) do
      {:ok, %{exit: 0, verdict_code: :claim, kid: kid, typ: typ}}
    else
      {:error, code} -> {:error, Profile.exit_of(code), code}
    end
  end

  defp known_key({:ok, pub}) when is_binary(pub), do: {:ok, pub}
  defp known_key(_unknown), do: {:error, :policy_stale_or_unknown_key}

  defp thumbprint_matches(pub, kid) when byte_size(pub) == @pub_size do
    if thumbprint(pub) == kid, do: :ok, else: {:error, :kid_not_thumbprint}
  end

  defp thumbprint_matches(_pub, _kid), do: {:error, :kid_not_thumbprint}

  defp signature_size(sig) when byte_size(sig) == @sig_size, do: :ok
  defp signature_size(_sig), do: {:error, :carrier_malformed}

  defp signature_valid(tbs, sig, pub) do
    if :crypto.verify(:mldsa87, :none, tbs, sig, pub), do: :ok, else: {:error, :signature_invalid}
  rescue
    e in ErlangError -> unavailable(e)
  end

  # :crypto raises :notsup in FIPS mode on a provider that refuses ML-DSA-87, and badarg where
  # the linked library has no ML-DSA at all. Either way this runtime cannot judge.
  defp unavailable(%ErlangError{original: {reason, _, _}}) when reason in [:notsup, :badarg],
    do: {:error, :alg_unavailable}

  defp unavailable(e), do: raise(e)

  @doc "The bytes of one exchange form of a Sign1."
  @spec render(parts(), :detached | :attached_tagged) :: binary()
  def render(%{protected: p, signature: s}, :detached),
    do: CBOR.encode!([{:bytes, p}, %{}, nil, {:bytes, s}])

  def render(%{protected: p, payload: payload, signature: s}, :attached_tagged),
    do: <<@tag18>> <> CBOR.encode!([{:bytes, p}, %{}, {:bytes, payload}, {:bytes, s}])

  @doc """
  The parts of a Sign1 in one exchange form. A detached Sign1 takes its payload separately. The
  unprotected header must be empty: `alg`, `kid` or `typ` there is `header_not_protected`, a
  countersignature label (7, 9, 11, 12) `countersignature_forbidden`, any other label
  `unprotected_forbidden`.
  """
  @spec parse(binary(), :detached, binary()) :: {:ok, parts()} | {:error, Profile.code()}
  @spec parse(binary(), :attached_tagged) :: {:ok, parts()} | {:error, Profile.code()}
  def parse(bytes, :detached, payload) when is_binary(bytes) and is_binary(payload) do
    with {:ok, [{:bytes, p}, unprotected, nil, {:bytes, s}]} <- sign1(bytes),
         :ok <- unprotected(unprotected) do
      {:ok, %{protected: p, payload: payload, signature: s}}
    else
      {:ok, _other} -> {:error, :carrier_malformed}
      {:error, code} -> {:error, code}
    end
  end

  def parse(<<@tag18, bytes::binary>>, :attached_tagged) do
    with {:ok, [{:bytes, p}, unprotected, {:bytes, payload}, {:bytes, s}]} <- sign1(bytes),
         :ok <- unprotected(unprotected) do
      {:ok, %{protected: p, payload: payload, signature: s}}
    else
      {:ok, _other} -> {:error, :carrier_malformed}
      {:error, code} -> {:error, code}
    end
  end

  def parse(bytes, :attached_tagged) when is_binary(bytes), do: {:error, :carrier_malformed}

  # The only map in a Sign1 is the unprotected header, so a key the codec refuses is one there.
  defp sign1(bytes) do
    case CBOR.decode(bytes) do
      {:ok, value} -> {:ok, value}
      {:error, :key_not_uint, _} -> {:error, :unprotected_forbidden}
      {:error, _code, _} -> {:error, :carrier_malformed}
    end
  end

  defp unprotected(map) when map == %{}, do: :ok

  defp unprotected(map) when is_map(map) do
    keys = Map.keys(map)

    cond do
      Enum.any?(keys, &(&1 in @required)) -> {:error, :header_not_protected}
      Enum.any?(keys, &(&1 in @countersignature)) -> {:error, :countersignature_forbidden}
      true -> {:error, :unprotected_forbidden}
    end
  end

  defp unprotected(_other), do: {:error, :carrier_malformed}
end
