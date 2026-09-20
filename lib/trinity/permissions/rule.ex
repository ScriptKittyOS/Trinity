# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Rule do
  @moduledoc """
  A row of `tool_permissions` (slice 021): a rule (`global` or `persona:<id>`, an argument
  glob) or a session grant (`session:<id>`, a fingerprint pattern `fp:<hex>`, an expiry).

  The pattern language: `*` matches any arguments; `<key>=<glob>` matches when the argument
  `key`, as text, matches the glob (`*` any run within a path segment, `**` across segments,
  `?` one character); a trailing `*` on a command is the prefix rule docs/07 asks for. Regex
  is not accepted from the UI; a hand-edited row may carry `re:<pattern>`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @decisions ~w(allow deny ask)

  @type t :: %__MODULE__{}

  schema "tool_permissions" do
    field :tool, :string
    field :pattern, :string, default: "*"
    field :decision, :string
    field :scope, :string, default: "global"
    field :expires_at, :utc_datetime_usec
    field :decided_by, :string
    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:tool, :pattern, :decision, :scope, :expires_at, :decided_by])
    |> validate_required([:tool, :pattern, :decision, :scope])
    |> validate_inclusion(:decision, @decisions)
    |> validate_format(:scope, ~r/^(global|session:.+|persona:.+)$/)
    |> validate_change(:pattern, fn :pattern, p ->
      if valid_pattern?(p),
        do: [],
        else: [pattern: "is not `*`, `key=glob`, `fp:<hex>` or `re:<regex>`"]
    end)
  end

  @doc "True when the arguments match the pattern (the fingerprint form takes the call's fingerprint)."
  @spec matches?(String.t(), map(), String.t() | nil) :: boolean()
  def matches?("*", _args, _fingerprint), do: true
  def matches?("fp:" <> hex, _args, fingerprint), do: hex == fingerprint

  def matches?("re:" <> re, args, _fingerprint) do
    case Regex.compile(re) do
      {:ok, regex} -> Enum.any?(args, fn {_k, v} -> Regex.match?(regex, to_string(v)) end)
      _ -> false
    end
  end

  def matches?(pattern, args, _fingerprint) do
    case String.split(pattern, "=", parts: 2) do
      [key, glob] when is_map_key(args, key) ->
        Regex.match?(glob_to_regex(glob), to_string(args[key]))

      _ ->
        false
    end
  end

  @doc "True for a pattern the changeset accepts."
  @spec valid_pattern?(term()) :: boolean()
  def valid_pattern?("*"), do: true
  def valid_pattern?("fp:" <> hex), do: String.match?(hex, ~r/^[0-9a-f]{64}$/)
  def valid_pattern?("re:" <> re), do: match?({:ok, _}, Regex.compile(re))
  def valid_pattern?(p) when is_binary(p), do: match?([_, _], String.split(p, "=", parts: 2))
  def valid_pattern?(_), do: false

  @doc "A glob as a regex: `**` any run, `*` any run without a separator, `?` one character."
  @spec glob_to_regex(String.t()) :: Regex.t()
  def glob_to_regex(glob) do
    source =
      glob
      |> String.split(~r/(\*\*|\*|\?)/, include_captures: true, trim: true)
      |> Enum.map_join(fn
        "**" -> ".*"
        "*" -> "[^/]*"
        "?" -> "."
        literal -> Regex.escape(literal)
      end)

    Regex.compile!("^" <> source <> "$")
  end
end
