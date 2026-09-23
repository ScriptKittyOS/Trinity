# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Identities do
  @moduledoc """
  Who may talk to Trinity from outside (slice 070): the `gateway_identities` rows and the pairing
  that creates them.

  The rule this module exists to hold, from docs/07: **an unknown sender gets a pairing prompt and
  nothing else.** No session is created, no model is called, nothing is remembered but the code
  that was shown. Pairing is proved on the desktop, where the owner already is: the code appears
  on `/gateways`, the sender types it back into the channel, and only then does the row become
  `paired`. A configured allowlist (`config :trinity, :gateways, allowlist: [{adapter, id}, …]`)
  pairs an id at first sight, for a deployment that already knows who it is talking to.

  A code is six characters from an alphabet without the letters and digits that are read for one
  another, lives ten minutes, and is compared in constant time.
  """

  import Ecto.Query, only: [from: 2]

  alias Trinity.Gateways.Identity
  alias Trinity.Repo

  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @code_length 6
  @code_ttl_s 600

  @doc "Every identity, newest first."
  @spec list() :: [Identity.t()]
  def list, do: Repo.all(from i in Identity, order_by: [desc: i.inserted_at])

  @doc "The identity for an adapter and an external id, or nil."
  @spec get(String.t(), String.t()) :: Identity.t() | nil
  def get(adapter, external_user_id),
    do: Repo.get_by(Identity, adapter: adapter, external_user_id: external_user_id)

  @doc """
  The identity an inbound message belongs to, creating a `pending` row with a fresh code when the
  sender is unknown, or a `paired` one when the allowlist already names them. The second element
  says what the caller must do: `:paired` to carry on, `:pending` to show the code and stop.
  """
  @spec admit(String.t(), String.t(), keyword()) ::
          {:ok, Identity.t(), :paired | :pending | :revoked} | {:error, Ecto.Changeset.t()}
  def admit(adapter, external_user_id, opts \\ []) do
    case get(adapter, external_user_id) do
      nil -> first_sight(adapter, external_user_id, opts)
      %Identity{state: "paired"} = identity -> {:ok, touch(identity, opts), :paired}
      %Identity{state: "revoked"} = identity -> {:ok, identity, :revoked}
      %Identity{} = identity -> {:ok, refresh_code(identity, opts), :pending}
    end
  end

  @doc """
  Answers a pairing attempt: the code the sender typed, against the code this identity was shown.
  Wrong or expired leaves the row pending, and says so rather than saying which.
  """
  @spec pair(String.t(), String.t(), String.t()) ::
          {:ok, Identity.t()} | {:error, :no_code | :wrong_code | :expired | :revoked}
  def pair(adapter, external_user_id, given) when is_binary(given) do
    with %Identity{} = identity <- get(adapter, external_user_id),
         :ok <- pairable(identity),
         :ok <- code_matches(identity, given),
         :ok <- code_live(identity) do
      {:ok,
       update!(identity, %{state: "paired", paired_at: now(), code: nil, code_expires_at: nil})}
    else
      nil -> {:error, :no_code}
      {:error, _} = error -> error
    end
  end

  @doc "Turns an identity away; the row stays, so the refusal is visible."
  @spec revoke(Identity.t()) :: {:ok, Identity.t()} | {:error, Ecto.Changeset.t()}
  def revoke(%Identity{} = identity),
    do: identity |> Identity.changeset(%{state: "revoked", revoked_at: now()}) |> Repo.update()

  @doc "Pairs an identity from the desktop, without a code (the owner is already proved here)."
  @spec allow(Identity.t()) :: {:ok, Identity.t()} | {:error, Ecto.Changeset.t()}
  def allow(%Identity{} = identity) do
    identity
    |> Identity.changeset(%{state: "paired", paired_at: now(), code: nil, code_expires_at: nil})
    |> Repo.update()
  end

  @doc "The identities waiting with a live code, for the page that shows them."
  @spec pending() :: [Identity.t()]
  def pending do
    now = now()

    Repo.all(
      from i in Identity,
        where: i.state == "pending" and i.code_expires_at > ^now,
        order_by: [desc: i.inserted_at]
    )
  end

  @doc """
  A fresh pairing code, from the cryptographically secure generator.

  The code is a credential: it is the whole of the proof that the person holding a channel is the
  person at this machine, so it is generated with `:crypto.strong_rand_bytes/1` and not with
  `Enum.random/1`, which draws from `:rand` and is predictable from observed output. The alphabet
  has 32 characters and a byte has 256 values, so mapping a byte with `rem/2` is uniform: 256 is
  exactly eight whole cycles of the alphabet, and no value is more likely than another.
  """
  @spec generate_code() :: String.t()
  def generate_code do
    size = length(@alphabet)

    for <<byte <- :crypto.strong_rand_bytes(@code_length)>>,
      into: "",
      do: <<Enum.at(@alphabet, rem(byte, size))>>
  end

  @doc "How long a code lives, in seconds."
  @spec code_ttl_s() :: pos_integer()
  def code_ttl_s, do: @code_ttl_s

  defp first_sight(adapter, external_user_id, opts) do
    attrs = %{
      adapter: adapter,
      external_user_id: external_user_id,
      display_name: Keyword.get(opts, :display_name),
      last_conversation: Keyword.get(opts, :conversation)
    }

    if allowlisted?(adapter, external_user_id) do
      insert(Map.merge(attrs, %{state: "paired", paired_at: now()}), :paired)
    else
      insert(
        Map.merge(attrs, %{state: "pending", code: generate_code(), code_expires_at: expiry()}),
        :pending
      )
    end
  end

  defp insert(attrs, state) do
    case %Identity{} |> Identity.changeset(attrs) |> Repo.insert() do
      {:ok, identity} -> {:ok, identity, state}
      {:error, _} = error -> error
    end
  end

  # A pending identity that comes back after its code expired is shown a new one: the alternative
  # is a sender who can never pair because the first code they were given has gone stale.
  defp refresh_code(identity, opts) do
    if live_code?(identity) do
      touch(identity, opts)
    else
      update!(identity, %{
        code: generate_code(),
        code_expires_at: expiry(),
        last_conversation: Keyword.get(opts, :conversation, identity.last_conversation)
      })
    end
  end

  defp touch(identity, opts) do
    case Keyword.get(opts, :conversation) do
      nil -> identity
      same when same == identity.last_conversation -> identity
      conversation -> update!(identity, %{last_conversation: conversation})
    end
  end

  defp update!(identity, attrs), do: identity |> Identity.changeset(attrs) |> Repo.update!()

  defp pairable(%Identity{state: "revoked"}), do: {:error, :revoked}
  defp pairable(%Identity{state: "paired"} = _identity), do: :ok
  defp pairable(%Identity{code: nil}), do: {:error, :no_code}
  defp pairable(%Identity{}), do: :ok

  defp code_matches(%Identity{code: nil}, _given), do: {:error, :no_code}

  defp code_matches(%Identity{code: code}, given) do
    given = given |> String.trim() |> String.upcase()

    if byte_size(given) == byte_size(code) and :crypto.hash_equals(given, code),
      do: :ok,
      else: {:error, :wrong_code}
  end

  defp code_live(identity), do: if(live_code?(identity), do: :ok, else: {:error, :expired})

  defp live_code?(%Identity{code: code, code_expires_at: at}),
    do: is_binary(code) and not is_nil(at) and DateTime.compare(at, now()) == :gt

  defp allowlisted?(adapter, external_user_id) do
    :trinity
    |> Application.get_env(:gateways, [])
    |> Keyword.get(:allowlist, [])
    |> Enum.any?(fn
      {a, id} -> to_string(a) == adapter and to_string(id) == external_user_id
      _ -> false
    end)
  end

  defp expiry, do: DateTime.add(now(), @code_ttl_s, :second)
  defp now, do: DateTime.utc_now()
end
