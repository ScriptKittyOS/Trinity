# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Personas do
  @moduledoc """
  Personas (slice 030): who Trinity is for a session. A persona is a name, a SOUL (the
  identity, tone and boundaries the system prompt opens with), a default model and settings
  (`permissions`: tool name to allow/deny/ask, the persona-level rule the gate consults).
  The row and its store are `Trinity.Sessions`'s since slice 010 (NOTES deviation a); this is
  the context the pages and the tools call, and the seed of the default persona from
  `priv/personas/default/SOUL.md` lives with the row's creation in `Trinity.Sessions.default_persona/0`.
  """
  use Boundary, deps: [Trinity, Trinity.Sessions], exports: []

  alias Trinity.Sessions
  alias Trinity.Sessions.Persona

  @doc "Every persona, by name."
  @spec list() :: [Persona.t()]
  def list, do: Sessions.list_personas()

  @doc "A persona by id, or nil."
  @spec get(String.t()) :: Persona.t() | nil
  def get(id), do: Sessions.get_persona(id)

  @doc "The default persona, seeded on first use."
  @spec default() :: Persona.t()
  def default, do: Sessions.default_persona()

  @doc "Creates a persona from `name`, `soul`, `model`, `settings`."
  @spec create(map()) :: {:ok, Persona.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: Sessions.create_persona(attrs)

  @doc "Updates a persona's soul, model or settings."
  @spec update(Persona.t(), map()) :: {:ok, Persona.t()} | {:error, Ecto.Changeset.t()}
  def update(%Persona{} = persona, attrs), do: Sessions.update_persona(persona, attrs)

  @doc """
  A quick edit of one setting under `settings`: `put_setting(persona, ["permissions", "memory"], "allow")`.
  """
  @spec put_setting(Persona.t(), [String.t()], term()) ::
          {:ok, Persona.t()} | {:error, Ecto.Changeset.t()}
  def put_setting(%Persona{settings: settings} = persona, path, value) when is_list(path) do
    update(persona, %{
      settings: put_in(settings || %{}, Enum.map(path, &Access.key(&1, %{})), value)
    })
  end

  @doc "The soul as the prompt opens with it: the persona's own, or the default fallback."
  @spec soul(Persona.t() | nil) :: String.t()
  def soul(%Persona{soul: soul}) when is_binary(soul) and soul != "", do: soul
  def soul(_), do: "You are Trinity."
end
