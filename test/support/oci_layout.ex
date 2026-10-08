# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.OCILayout do
  @moduledoc """
  Test-only (slice 134): builds the OCI image layout the Tier 3 import path takes, signed in the
  shape cosign v3.1.3 writes with `cosign sign --key ... --use-signing-config=false
  --tlog-upload=false` and `cosign save` (observed 2026-10-08, slice 134 NOTES): `index.json`
  lists the image manifest only; the signature is a referrer manifest whose `subject` is the image
  manifest and whose one layer is a Sigstore bundle v0.3 holding a DSSE envelope over an in-toto
  statement naming the image manifest's digest.

  The keys are made by the test (`key!/0`, P-256) and written only under the test's temporary
  directory. The real `cosign` is what verifies the result (the `:signing_tools` cases), so a
  layout it would not accept fails the valid case rather than passing a test of mine.
  """

  @empty_config ~s({})
  @oci_manifest "application/vnd.oci.image.manifest.v1+json"
  @bundle_type "application/vnd.dev.sigstore.bundle.v0.3+json"
  @secp256r1 {1, 2, 840, 10_045, 3, 1, 7}

  @doc "A fresh P-256 key pair: `%{private: record, public_pem: binary, private_pem: binary, der: binary}`."
  @spec key!() :: map()
  def key! do
    priv = :public_key.generate_key({:namedCurve, @secp256r1})
    {:ECPrivateKey, _v, _d, _params, point, _attrs} = priv
    spki = {{:ECPoint, point}, {:namedCurve, @secp256r1}}
    {_, der, _} = entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, spki)

    %{
      private: priv,
      der: der,
      public_pem: :public_key.pem_encode([entry]),
      private_pem: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, priv)])
    }
  end

  @doc "Writes a key pair's halves under `dir`: `{public_path, private_path}`."
  @spec write_key!(map(), Path.t(), String.t()) :: {Path.t(), Path.t()}
  def write_key!(key, dir, name) do
    pub = Path.join(dir, name <> ".pub")
    priv = Path.join(dir, name <> ".key")
    File.write!(pub, key.public_pem)
    File.write!(priv, key.private_pem)
    File.chmod!(priv, 0o600)
    {pub, priv}
  end

  @doc """
  Writes a layout into `dir` holding `files` (`[{title, bytes}]`) as layers, signed with
  `cosign_key` (a `key!/0` map, or nil for none). Options: `sign_digest:` signs that manifest
  digest instead of this one's (a valid signature over another artifact); `flip_signature:` flips
  one bit of the signature. Returns the image manifest's digest.
  """
  @spec build!(Path.t(), [{String.t(), binary()}], map() | nil, keyword()) :: String.t()
  def build!(dir, files, cosign_key, opts \\ []) do
    File.mkdir_p!(Path.join([dir, "blobs", "sha256"]))
    File.write!(Path.join(dir, "oci-layout"), ~s({"imageLayoutVersion":"1.0.0"}))
    config = blob!(dir, @empty_config)

    layers =
      for {title, bytes} <- files do
        bytes
        |> then(&blob!(dir, &1))
        |> Map.merge(%{
          "mediaType" => "application/octet-stream",
          "annotations" => %{"org.opencontainers.image.title" => title}
        })
      end

    manifest =
      Jason.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => @oci_manifest,
        "artifactType" => "application/vnd.trinity.tier3.model.v1",
        "config" => Map.put(config, "mediaType", "application/vnd.oci.empty.v1+json"),
        "layers" => layers
      })

    image = blob!(dir, manifest) |> Map.put("mediaType", @oci_manifest)

    index = %{
      "schemaVersion" => 2,
      "mediaType" => "application/vnd.oci.image.index.v1+json",
      "manifests" => [
        Map.put(image, "annotations", %{"kind" => "dev.cosignproject.cosign/image"})
      ]
    }

    File.write!(Path.join(dir, "index.json"), Jason.encode!(index))
    if cosign_key, do: sign!(dir, image, cosign_key, config, opts)
    image["digest"]
  end

  defp sign!(dir, image, key, config, opts) do
    "sha256:" <> hex = Keyword.get(opts, :sign_digest, image["digest"])

    statement =
      Jason.encode!(%{
        "_type" => "https://in-toto.io/Statement/v1",
        "subject" => [%{"digest" => %{"sha256" => hex}, "annotations" => %{}}],
        "predicateType" => "https://sigstore.dev/cosign/sign/v1",
        "predicate" => %{}
      })

    type = "application/vnd.in-toto+json"
    pae = "DSSEv1 #{byte_size(type)} #{type} #{byte_size(statement)} #{statement}"
    sig = :public_key.sign(pae, :sha256, key.private)
    sig = if Keyword.get(opts, :flip_signature), do: flip(sig, 10), else: sig

    bundle =
      Jason.encode!(%{
        "mediaType" => @bundle_type,
        "verificationMaterial" => %{
          "publicKey" => %{"hint" => Base.encode64(:crypto.hash(:sha256, key.der))}
        },
        "dsseEnvelope" => %{
          "payload" => Base.encode64(statement),
          "payloadType" => type,
          "signatures" => [%{"sig" => Base.encode64(sig)}]
        }
      })

    bundle_desc = blob!(dir, bundle) |> Map.put("mediaType", @bundle_type)

    referrer =
      Jason.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => @oci_manifest,
        "artifactType" => @bundle_type,
        "config" =>
          Map.merge(config, %{
            "mediaType" => "application/vnd.oci.empty.v1+json",
            "artifactType" => @bundle_type
          }),
        "layers" => [bundle_desc],
        "annotations" => %{
          "dev.sigstore.bundle.content" => "dsse-envelope",
          "dev.sigstore.bundle.predicateType" => "https://sigstore.dev/cosign/sign/v1"
        },
        "subject" => image
      })

    blob!(dir, referrer)
  end

  @doc ~s(Writes bytes as a blob: the descriptor `%{"digest", "size"}`.)
  @spec blob!(Path.t(), binary()) :: map()
  def blob!(dir, bytes) do
    hex = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    File.write!(Path.join([dir, "blobs", "sha256", hex]), bytes)
    %{"digest" => "sha256:" <> hex, "size" => byte_size(bytes)}
  end

  @doc "One bit of `bin` flipped at byte `at`."
  @spec flip(binary(), non_neg_integer()) :: binary()
  def flip(bin, at) do
    <<pre::binary-size(^at), b, rest::binary>> = bin
    <<pre::binary, Bitwise.bxor(b, 1), rest::binary>>
  end

  @doc "Flips one bit of the blob holding layer `title` in place (a byte flipped in transit)."
  @spec flip_layer!(Path.t(), String.t(), non_neg_integer()) :: :ok
  def flip_layer!(dir, title, at \\ 100) do
    [desc] =
      layers(dir) |> Enum.filter(&(&1["annotations"]["org.opencontainers.image.title"] == title))

    "sha256:" <> hex = desc["digest"]
    path = Path.join([dir, "blobs", "sha256", hex])
    File.write!(path, flip(File.read!(path), at))
  end

  defp layers(dir) do
    %{"manifests" => [%{"digest" => "sha256:" <> hex}]} =
      Jason.decode!(File.read!(Path.join(dir, "index.json")))

    Jason.decode!(File.read!(Path.join([dir, "blobs", "sha256", hex])))["layers"]
  end
end
