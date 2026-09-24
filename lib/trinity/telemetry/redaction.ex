# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Telemetry.Redaction do
  @moduledoc """
  A `Logger` filter that masks credentials and truncates long content (slice 090).

  **A filter is a last line, not the control.** The controls are that key material lives in files
  outside configuration (slice 025), that the authorization layer's records carry no token
  (slice 062), and that telemetry events carry no content at all (`docs/telemetry.md`). This exists
  because logs are written by every library in the tree as well as by this project, and a
  dependency that logs a request header has not read any of those rules.

  So it is deliberately blunt. It masks anything *shaped* like a credential rather than anything
  known to be one, and it truncates long messages. Over-masking a log line costs a reader some
  context; under-masking one puts a key on disk.

  ## What it cannot do

  It sees the message and its metadata, not the intent. A key embedded in a sentence with no
  recognisable shape passes through, and a chat message that happens to look like a bearer token is
  masked. Neither is a defect in the filter; both are why it is not the control.
  """

  @max_chars 2_000

  # Shapes rather than names. Each is anchored on a prefix that exists to be recognised, which is
  # the property that makes a credential's own format give it away.
  @patterns [
    {~r/(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+\/=-]{12,}/, "\\1 [REDACTED]"},
    {~r/\b(?:sk|pk|rk|api|key)[-_][A-Za-z0-9._-]{16,}/i, "[REDACTED]"},
    {~r/\bey[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/, "[REDACTED-JWT]"},
    {~r/(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token|private[_-]?key)(\s*[:=]\s*)\S+/,
     "\\1\\2[REDACTED]"}
  ]

  @doc """
  The filter. Returns the event with its message and metadata masked, never `:stop`.

  Never `:stop`, on purpose: a filter that drops a line to avoid printing a secret also drops the
  evidence that something happened. Masking keeps the event and removes the value.
  """
  @spec filter(map(), term()) :: map()
  def filter(%{msg: msg, meta: meta} = event, _opts) do
    %{event | msg: redact_msg(msg), meta: redact_meta(meta)}
  end

  def filter(event, _opts), do: event

  @doc "Masks credential-shaped substrings in a binary."
  @spec redact(term()) :: term()
  def redact(text) when is_binary(text) do
    Enum.reduce(@patterns, text, fn {re, replacement}, acc ->
      Regex.replace(re, acc, replacement)
    end)
  end

  def redact(other), do: other

  @doc "Truncates to the logging limit, saying how much was dropped rather than trailing off."
  @spec truncate(binary(), pos_integer()) :: binary()
  def truncate(text, max \\ @max_chars) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "… [#{String.length(text) - max} more characters]"
    else
      text
    end
  end

  @doc "The character limit applied to a logged message."
  @spec max_chars() :: pos_integer()
  def max_chars, do: @max_chars

  defp redact_msg({:string, text}) when is_binary(text),
    do: {:string, text |> redact() |> truncate()}

  defp redact_msg({format, args}) when is_list(args), do: {format, Enum.map(args, &redact_term/1)}
  defp redact_msg({:report, report}), do: {:report, redact_term(report)}
  defp redact_msg(other), do: other

  defp redact_meta(meta) when is_map(meta),
    do: Map.new(meta, fn {k, v} -> {k, redact_term(v)} end)

  defp redact_meta(meta), do: meta

  defp redact_term(v) when is_binary(v), do: v |> redact() |> truncate()
  defp redact_term(v) when is_list(v), do: Enum.map(v, &redact_term/1)
  defp redact_term(%{__struct__: _} = v), do: v
  defp redact_term(v) when is_map(v), do: Map.new(v, fn {k, val} -> {k, redact_term(val)} end)
  defp redact_term({a, b}), do: {redact_term(a), redact_term(b)}
  defp redact_term(v), do: v
end
