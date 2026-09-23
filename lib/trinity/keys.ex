# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Keys do
  @moduledoc """
  Where key material comes from, and the only place in this tree that touches it (slice 025).

  Two consumers sit above this seam and neither knows what is beneath it: the receipt signer
  (slice 024), which needs a private key to sign a chain, and this slice's envelope encryption,
  which needs a data key wrapped so it can be stored beside the ciphertext it opens.

  **Why a behaviour before there is a second adapter.** A deployment that keeps keys in a KMS or
  an HSM should be able to say so in configuration rather than in a patch. Shaping that seam after
  two consumers have grown their own key handling is a rewrite; shaping it now is four callbacks.
  The behaviour is deliberately shaped around a *local* round trip, so that a network adapter later
  has to fit a callback that was proven without one, rather than the callbacks being widened to
  whatever a particular network service happens to offer.

  ## The four operations

    * `fetch/2` - the named key, created on first use. For a signer: its private key.
    * `wrap/2` - seal a data key so it can be written beside the blob it opens.
    * `unwrap/2` - open one again.
    * `rotate/1` - begin using a new key without losing the ability to open what the old one sealed.

  `describe/0` names the adapter and the source in force, for the boot receipt. It returns no key
  material and never will: a receipt that carried a key would defeat the chain it is part of.

  ## What this seam does not promise

  It says where key material comes from. It does not make a machine trustworthy: a local adapter
  on a machine an attacker already controls protects nothing, and the honest description of the
  passphrase source is that it moves the secret from a file to a person's memory and the deployment's
  environment. What it does buy, today, is that a later move to a KMS touches this module and
  nothing else.
  """

  # A top-level boundary, not a sub-boundary of `Trinity`: a sub-boundary inherits its ancestors'
  # dependencies unless it says otherwise, so a nested `deps: []` would be a claim the compiler
  # never checks. Slice 062 shipped exactly that mistake and this slice does not repeat it.
  use Boundary, top_level?: true, deps: [], exports: [Local]

  @typedoc "What a key is called. Stable across rotations; the key id beneath it is not."
  @type name :: atom() | String.t()

  @typedoc "An opaque handle to wrapped key material, safe to write to disk beside a blob."
  @type wrapped :: binary()

  @typedoc "How the adapter obtained its root key, for the record rather than for the caller."
  @type description :: %{
          adapter: module(),
          source: atom(),
          key_id: String.t(),
          detail: String.t()
        }

  @doc "The named key's material, creating it on first use."
  @callback fetch(name(), keyword()) :: {:ok, binary()} | {:error, term()}

  @doc "Seals key material so it can be stored beside what it opens."
  @callback wrap(binary(), keyword()) :: {:ok, wrapped()} | {:error, term()}

  @doc "Opens what `wrap/2` sealed, including material sealed by a superseded key."
  @callback unwrap(wrapped(), keyword()) :: {:ok, binary()} | {:error, term()}

  @doc "Begins using a new root key. What the old one sealed must still open."
  @callback rotate(keyword()) :: {:ok, description()} | {:error, term()}

  @doc "The adapter and source in force. Never key material."
  @callback describe() :: description() | {:error, term()}

  @doc "The adapter in force: `config :trinity, :keys, adapter: Mod`, else the local one."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:trinity, :keys, [])[:adapter] || Trinity.Keys.Local
  end

  @doc "The named key's material, through the adapter in force."
  @spec fetch(name(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch(name, opts \\ []), do: adapter().fetch(name, opts)

  @doc "Seals key material through the adapter in force."
  @spec wrap(binary(), keyword()) :: {:ok, wrapped()} | {:error, term()}
  def wrap(material, opts \\ []) when is_binary(material), do: adapter().wrap(material, opts)

  @doc "Opens sealed key material through the adapter in force."
  @spec unwrap(wrapped(), keyword()) :: {:ok, binary()} | {:error, term()}
  def unwrap(wrapped, opts \\ []) when is_binary(wrapped), do: adapter().unwrap(wrapped, opts)

  @doc "Rotates the root key through the adapter in force."
  @spec rotate(keyword()) :: {:ok, description()} | {:error, term()}
  def rotate(opts \\ []), do: adapter().rotate(opts)

  @doc "The adapter and source in force, for the boot receipt."
  @spec describe() :: description() | {:error, term()}
  def describe, do: adapter().describe()
end
