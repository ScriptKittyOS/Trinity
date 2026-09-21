# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.ServerConfig do
  @moduledoc """
  One row of `mcp_servers` (slice 060, docs/05): a server the client connects to. `name` is
  the namespace segment of every tool the server contributes (`mcp:<name>:<tool>`), so it is
  short and closed to anything the tier lookup could confuse; `transport` is `stdio` (a
  `command` with `args`, the child's environment holding only the variables `env_refs`
  names) or `http` (a `url`). `effect_default` is the effect class every tool gets unless
  `tool_overrides` names it; `catalog` is not a value either may take, because the effect
  catalog is compile time (docs/07) and a server cannot enter it.

  Not `Trinity.MCP.Server`: that name is slice 061's, the server Trinity exposes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  @transports ~w(stdio http)
  @effects ~w(none artifact)
  @name_pattern ~r/^[a-z0-9][a-z0-9_-]{0,31}$/

  schema "mcp_servers" do
    field :name, :string
    field :transport, :string
    field :command, :string
    field :args, {:array, :string}, default: []
    field :url, :string
    field :env_refs, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :effect_default, :string, default: "none"
    field :tool_overrides, :map, default: %{}
    field :last_error, :string
    timestamps()
  end

  @doc "The transports, and the effect classes a server's tools may carry."
  @spec transports() :: [String.t()]
  def transports, do: @transports
  @spec effects() :: [String.t()]
  def effects, do: @effects

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :name,
      :transport,
      :command,
      :args,
      :url,
      :env_refs,
      :enabled,
      :effect_default,
      :tool_overrides,
      :last_error
    ])
    |> validate_required([:name, :transport])
    |> validate_format(:name, @name_pattern,
      message: "must be 1 to 32 characters of a-z, 0-9, _ or -, starting with a letter or digit"
    )
    |> validate_inclusion(:transport, @transports)
    |> validate_inclusion(:effect_default, @effects)
    |> validate_transport()
    |> validate_env_refs()
    |> validate_overrides()
    |> unique_constraint(:name)
  end

  defp validate_transport(changeset) do
    case get_field(changeset, :transport) do
      "stdio" ->
        changeset
        |> validate_required([:command], message: "a stdio server needs a command")
        |> validate_change(:url, fn :url, _ -> [url: "a stdio server has no url"] end)

      "http" ->
        changeset
        |> validate_required([:url], message: "an http server needs a url")
        |> validate_change(:url, &url_error/2)
        |> validate_change(:command, fn :command, _ ->
          [command: "an http server has no command"]
        end)

      _ ->
        changeset
    end
  end

  defp url_error(:url, url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        []

      _ ->
        [url: "must be an http or https URL with a host"]
    end
  end

  # An env ref is a variable's name, never its value: a value here would be a secret in a row.
  defp validate_env_refs(changeset) do
    validate_change(changeset, :env_refs, fn :env_refs, refs ->
      if Enum.all?(refs, &Regex.match?(~r/^[A-Z_][A-Z0-9_]*$/, &1)),
        do: [],
        else: [env_refs: "must be environment variable names (A-Z, 0-9, _)"]
    end)
  end

  # An override is `%{"effect" => none | artifact}` per tool name; `catalog` is refused here
  # so a row can never claim it (the registry refuses it too, and the load path receipts a
  # refusal: AC3). No other key is known.
  defp validate_overrides(changeset) do
    validate_change(changeset, :tool_overrides, fn :tool_overrides, overrides ->
      Enum.flat_map(overrides, fn
        {tool, %{} = o} when is_binary(tool) ->
          effect_errors(tool, Map.get(o, "effect")) ++ key_errors(tool, Map.keys(o))

        {tool, _} ->
          [tool_overrides: "#{tool}: an override is a map"]
      end)
    end)
  end

  defp effect_errors(_tool, nil), do: []
  defp effect_errors(_tool, effect) when effect in @effects, do: []

  defp effect_errors(tool, "catalog"),
    do: [tool_overrides: "#{tool}: catalog is compile time and cannot be claimed"]

  defp effect_errors(tool, other),
    do: [tool_overrides: "#{tool}: unknown effect #{inspect(other)}"]

  defp key_errors(tool, keys) do
    case keys -- ["effect"] do
      [] ->
        []

      other ->
        [
          tool_overrides:
            "#{tool}: unknown key#{if length(other) > 1, do: "s"} #{Enum.join(other, ", ")}"
        ]
    end
  end
end
