# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.COSE do
  @moduledoc """
  COSE_Sign1 under the N6 profile (its section 5; slice 138): the header rules, the key
  thumbprint, signing and verifying. ML-DSA-87 (-50) at every entry point; Ed25519 (-19) on the
  `commercial` profile only (slice 139, the profile publisher's answers of 2026-10-19).

  ## The protected header

      {1: alg, 4: kid, 16: typ, ? 15: {1: iss, 2: sub}}

  `alg` -50 is ML-DSA-87 (RFC 9964), pure, with an empty context string (RFC 9964 section 5).
  `alg` -19 is Ed25519 (RFC 9864), pure EdDSA as RFC 8032 section 5.1 defines it.

  `kid` is the RFC 9679 COSE Key Thumbprint, SHA-384, encoded under RFC 8949 section 4.2.1:

    * for ML-DSA-87, over the AKP members RFC 9964 section 6 names, `{1: 7, 3: -50, -1: pub}`, which
      for a 2,592-byte key is exactly `a3 01 07 03 38 31 20 59 0a 20` followed by the key. The
      thumbprint includes `alg`, so the key cannot be used with another algorithm;
    * for Ed25519, over the OKP members RFC 9679 section 4.1 names, `{1: 1, -1: 6, -2: x}` (OKP and
      Ed25519 are 1 and 6 in RFC 9053 section 7.1), which for a 32-byte key is exactly
      `a3 01 01 20 06 21 58 20` followed by the key. This thumbprint has no `alg`, so the binding
      comes from elsewhere: the profile table binds each `typ` to its one algorithm, and a key is
      registered with its algorithm, which must be the header's.

  `typ` (RFC 9596) is a media type, compared byte for byte against the table the caller passes.
  Each entry names the `typ`'s one `alg`, its carrier and signers (`Trinity.N6.Carrier` reads
  those), and whether it is SCITT-renderable: CWT claims (label 15) are present exactly when it is.

  ## Entry points

  The caller says which entry point it is (`entry:`, `:nss` when it says nothing). At `:nss` only
  -50 is permitted; at `:commercial`, -50 and -19. A header whose `alg` is not the one its `typ` is
  bound to is refused at either. All three refusals are `alg_not_permitted`.

  The protected label set, for both algorithms, is closed to {1, 4, 15, 16}: content type (3) is refused with its own
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
  runtime cannot run the header's algorithm at all (`alg_unavailable`, this tree's code; FIPS mode
  refuses Ed25519). A runtime that refuses the algorithm is never a crash and never a pass. The
  attribution classes 6 and 7 need the profile's key descriptors and are not decided here.

  ## Keys

  A key names its algorithm: `%{alg: -50 | -19, public: pub, private: priv}` to sign, and
  `{:ok, %{alg: alg, public: pub}}` from the `keys` function a verifier passes. The algorithm comes
  from the key's registration, never from its size or from the header.

  An ML-DSA-87 private key is the 32-byte seed RFC 9964 section 4 defines, as `{:seed, seed}`, or
  the expanded key OTP's `generate_key/2` returns; `alg` may be left out, as it was before slice
  139. The public key is passed beside it: on OTP 28.5.0.8 no form of `:crypto.generate_key/3`
  derives it from a seed. An Ed25519 private key is its 32-byte secret (RFC 8032 section 5.1.5).
  """

  alias Trinity.N6.{CBOR, Profile}

  @mldsa87 -50
  @ed25519 -19
  @sizes %{@mldsa87 => %{public: 2592, signature: 4627}, @ed25519 => %{public: 32, signature: 64}}
  @permitted %{nss: [@mldsa87], commercial: [@mldsa87, @ed25519]}
  @akp_prefix <<0xA3, 0x01, 0x07, 0x03, 0x38, 0x31, 0x20, 0x59, 0x0A, 0x20>>
  @okp_prefix <<0xA3, 0x01, 0x01, 0x20, 0x06, 0x21, 0x58, 0x20>>
  @labels [1, 4, 15, 16]
  @required [1, 4, 16]
  @countersignature [7, 9, 11, 12]
  @tag18 0xD2

  @typedoc "One COSE_Sign1: the protected header bytes, the payload, the signature."
  @type parts :: %{protected: binary(), payload: binary(), signature: binary()}

  @typedoc "An algorithm N6 permits somewhere: -50 (ML-DSA-87) or -19 (Ed25519)."
  @type alg :: -50 | -19

  @typedoc "The entry point a verifier is: the `nss` profile, or `commercial`."
  @type entry_point :: :nss | :commercial

  @typedoc """
  The `typ` values an entry point accepts: each one's algorithm, carrier, signers, and whether it is
  SCITT-renderable.
  """
  @type typ_table :: %{
          optional(String.t()) => %{
            required(:scitt) => boolean(),
            required(:alg) => alg(),
            optional(:carrier) => :single | :envelope | :note,
            optional(:signers) => :single | :pair
          }
        }

  @typedoc "A signing key: its algorithm, its public key, and its private key."
  @type key :: %{
          optional(:alg) => alg(),
          public: binary(),
          private: {:seed, binary()} | binary()
        }

  @doc "The RFC 9679 SHA-384 thumbprint of an ML-DSA-87 public key: its `kid`."
  @spec thumbprint(binary()) :: binary()
  def thumbprint(pub), do: thumbprint(@mldsa87, pub)

  @doc "The RFC 9679 SHA-384 thumbprint of a public key of an algorithm: its `kid`."
  @spec thumbprint(alg(), binary()) :: binary()
  def thumbprint(@mldsa87, pub) when byte_size(pub) == 2592,
    do: :crypto.hash(:sha384, @akp_prefix <> pub)

  def thumbprint(@ed25519, pub) when byte_size(pub) == 32,
    do: :crypto.hash(:sha384, @okp_prefix <> pub)

  @doc """
  The protected header bytes for a `kid` and `typ`, with CWT `{iss, sub}` when given, under `alg`
  (-50 when not given).
  """
  @spec protected_header(binary(), String.t(), {String.t(), String.t()} | nil, alg()) :: binary()
  def protected_header(kid, typ, cwt \\ nil, alg \\ @mldsa87)
      when byte_size(kid) == 48 and is_binary(typ) and is_map_key(@sizes, alg) do
    header = %{1 => alg, 4 => {:bytes, kid}, 16 => {:text, typ}}

    header =
      case cwt do
        {iss, sub} -> Map.put(header, 15, %{1 => {:text, iss}, 2 => {:text, sub}})
        nil -> header
      end

    CBOR.encode!(header)
  end

  @doc """
  Strictly decodes protected header bytes under the header rules, a `typ` table and an entry point
  (`:nss` when none is given). The result carries the `typ`'s table entry, for the carrier rules.
  """
  @spec decode_protected(binary(), typ_table(), entry_point()) ::
          {:ok, %{alg: alg(), kid: binary(), typ: String.t(), cwt: map() | nil, entry: map()}}
          | {:error, Profile.code()}
  def decode_protected(bytes, table, entry_point \\ :nss)
      when is_binary(bytes) and is_map(table) and is_map_key(@permitted, entry_point) do
    with {:ok, header} <- decode_header_map(bytes),
         :ok <- labels(header),
         :ok <- present(header),
         {:ok, alg} <- alg(header),
         :ok <- permitted(alg, entry_point),
         {:ok, kid} <- kid(header),
         {:ok, typ, entry} <- typ(header, table),
         :ok <- bound(alg, entry),
         {:ok, cwt} <- cwt(header, entry) do
      {:ok, %{alg: alg, kid: kid, typ: typ, cwt: cwt, entry: entry}}
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

  defp alg(%{1 => alg}) when is_map_key(@sizes, alg), do: {:ok, alg}
  defp alg(_header), do: {:error, :alg_not_permitted}

  defp permitted(alg, entry_point) do
    if alg in Map.fetch!(@permitted, entry_point), do: :ok, else: {:error, :alg_not_permitted}
  end

  # The publisher's answer of 2026-10-19: the table binds each `typ` to its one algorithm.
  defp bound(alg, %{alg: alg}), do: :ok
  defp bound(_alg, _entry), do: {:error, :alg_not_permitted}

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
  Signs a payload as a Sign1 with the key's algorithm. `opts`: `cwt: {iss, sub}` for a
  SCITT-renderable `typ`. Answers `{:error, :alg_unavailable}` where the runtime cannot sign it.
  """
  @spec sign(binary(), String.t(), key(), keyword()) :: {:ok, parts()} | {:error, Profile.code()}
  def sign(payload, typ, key, opts \\ [])

  def sign(payload, typ, %{alg: @ed25519, public: pub, private: priv}, opts)
      when is_binary(payload) and byte_size(pub) == 32 and is_binary(priv) and
             byte_size(priv) == 32 do
    protected =
      protected_header(thumbprint(@ed25519, pub), typ, Keyword.get(opts, :cwt), @ed25519)

    signed(protected, payload, &:crypto.sign(:eddsa, :none, &1, [priv, :ed25519]))
  end

  def sign(payload, typ, %{public: pub, private: priv} = key, opts)
      when is_binary(payload) and byte_size(pub) == 2592 and
             (not is_map_key(key, :alg) or :erlang.map_get(:alg, key) == @mldsa87) do
    priv = mldsa87_private!(priv)
    protected = protected_header(thumbprint(pub), typ, Keyword.get(opts, :cwt))
    signed(protected, payload, &:crypto.sign(:mldsa87, :none, &1, priv))
  end

  # The two forms of an ML-DSA-87 private key OTP signs with: the expanded key, and the seed.
  defp mldsa87_private!(priv) when is_binary(priv) and byte_size(priv) == 4896, do: priv
  defp mldsa87_private!({:seed, seed} = priv) when byte_size(seed) == 32, do: priv

  defp signed(protected, payload, sign) do
    signature = sign.(to_be_signed(protected, payload))
    {:ok, %{protected: protected, payload: payload, signature: signature}}
  rescue
    e in ErlangError -> unavailable(e)
  end

  @doc """
  Verifies a Sign1's parts. `opts`: `keys`, a function from a `kid` to
  `{:ok, %{alg: alg, public: public_key}}` or `:error`; `typ`, the `typ` table of the entry point in
  use; `entry`, the entry point (`:nss` when not given).
  """
  @spec verify(parts(), keyword()) ::
          {:ok, %{exit: 0, verdict_code: :claim, kid: binary(), typ: String.t()}}
          | {:error, 1 | 5, Profile.code()}
  def verify(%{protected: protected, payload: payload, signature: signature}, opts)
      when is_binary(protected) and is_binary(payload) and is_binary(signature) do
    keys = Keyword.fetch!(opts, :keys)
    table = Keyword.fetch!(opts, :typ)
    entry_point = Keyword.get(opts, :entry, :nss)

    with {:ok, %{alg: alg, kid: kid, typ: typ}} <- decode_protected(protected, table, entry_point),
         {:ok, pub} <- known_key(keys.(kid), alg),
         :ok <- thumbprint_matches(alg, pub, kid),
         :ok <- signature_size(alg, signature),
         :ok <- signature_valid(alg, to_be_signed(protected, payload), signature, pub) do
      {:ok, %{exit: 0, verdict_code: :claim, kid: kid, typ: typ}}
    else
      {:error, code} -> {:error, Profile.exit_of(code), code}
    end
  end

  # A key registered under another algorithm than the header's is the draft's C5 case, a key used
  # with another algorithm, whatever its thumbprint: for OKP the thumbprint cannot say.
  defp known_key({:ok, %{alg: alg, public: pub}}, alg) when is_binary(pub), do: {:ok, pub}

  defp known_key({:ok, %{alg: _other, public: pub}}, _alg) when is_binary(pub),
    do: {:error, :kid_not_thumbprint}

  defp known_key(_unknown, _alg), do: {:error, :policy_stale_or_unknown_key}

  defp thumbprint_matches(alg, pub, kid) do
    if byte_size(pub) == @sizes[alg].public and thumbprint(alg, pub) == kid,
      do: :ok,
      else: {:error, :kid_not_thumbprint}
  end

  defp signature_size(alg, sig) do
    if byte_size(sig) == @sizes[alg].signature, do: :ok, else: {:error, :carrier_malformed}
  end

  defp signature_valid(alg, tbs, sig, pub) do
    if crypto_verify(alg, tbs, sig, pub), do: :ok, else: {:error, :signature_invalid}
  rescue
    e in ErlangError -> unavailable(e)
  end

  defp crypto_verify(@mldsa87, tbs, sig, pub), do: :crypto.verify(:mldsa87, :none, tbs, sig, pub)

  defp crypto_verify(@ed25519, tbs, sig, pub),
    do: :crypto.verify(:eddsa, :none, tbs, sig, [pub, :ed25519])

  # How :crypto says the runtime cannot do the algorithm, each measured: `badarg` ("Bad key type",
  # "Bad digest type") where the linked OpenSSL has no ML-DSA (3.0); `error` ("Can't create
  # PKEY_CTX from id") from `verify` in FIPS mode on Red Hat's provider (the `fips` job, PR #133);
  # `notsup` ("Unsupported algorithm in FIPS mode") for an algorithm the mode refuses, Ed25519 among
  # them. `:crypto` raises the same shapes for a malformed public key, but the key's size and its
  # thumbprint are checked before any call here, so these are the runtime's answer, not the
  # caller's mistake: no trust.
  defp unavailable(%ErlangError{original: {reason, _, _}})
       when reason in [:notsup, :badarg, :error],
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

  @doc """
  Checks a Sign1's unprotected header, which must be empty: `alg`, `kid` or `typ` there is
  `header_not_protected`, a countersignature label `countersignature_forbidden`, any other label
  `unprotected_forbidden`, and anything but a map `carrier_malformed`.
  """
  @spec unprotected(term()) :: :ok | {:error, Profile.code()}
  def unprotected(map) when map == %{}, do: :ok

  def unprotected(map) when is_map(map) do
    keys = Map.keys(map)

    cond do
      Enum.any?(keys, &(&1 in @required)) -> {:error, :header_not_protected}
      Enum.any?(keys, &(&1 in @countersignature)) -> {:error, :countersignature_forbidden}
      true -> {:error, :unprotected_forbidden}
    end
  end

  def unprotected(_other), do: {:error, :carrier_malformed}
end
