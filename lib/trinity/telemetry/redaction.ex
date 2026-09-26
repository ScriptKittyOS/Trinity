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

  ## It cannot raise, and that is a security property (slice 125)

  OTP removes a primary filter that raises, **permanently**, and carries on. Everything logged
  after that point is unredacted while the system believes it is not. So the interesting question
  about this module is not what it masks but whether it can be made to fail, and the answer has to
  be no for every input rather than for the inputs someone thought of.

  Two ways it used to fail, both found on a running server rather than by a test:

  - `Enum.map/2` was called on the message body. OTP chardata is routinely an **improper** list
    whose tail is a binary rather than `[]`, and `Enum.map/2` raises `FunctionClauseError` on one.
    A `db_connection` disconnect is enough to produce it. Lists are now walked by a function that
    handles an improper tail, and `{:string, chardata}` is flattened rather than mapped.
  - `Regex.replace/3` was called on any binary. A binary that is not valid UTF-8 raises, and raw
    key material is exactly the kind of thing that arrives as bytes rather than text. An invalid
    binary is now replaced outright rather than matched: it is not text a reader was meant to see,
    and it is the shape a secret is most likely to take.

  Beyond both, `filter/2` wraps its own work and degrades to an event that says the content was
  withheld. Losing a log line's detail is recoverable; running unfiltered is not.

  `Trinity.Application.verify_log_redaction!/0` refuses to let the application boot without this
  filter installed, so "it was quietly missing" is not a state the system can be in.

  ## What it cannot do

  It sees the message and its metadata, not the intent. A key embedded in a sentence with no
  recognisable shape passes through, and a chat message that happens to look like a bearer token is
  masked. Neither is a defect in the filter; both are why it is not the control.
  """

  @max_chars 2_000
  @max_reason_chars 200

  # Shapes rather than names. Each is anchored on a prefix that exists to be recognised, which is
  # the property that makes a credential's own format give it away.
  @patterns [
    {~r/(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+\/=-]{12,}/, "\\1 [REDACTED]"},
    {~r/\b(?:sk|pk|rk|api|key)[-_][A-Za-z0-9._-]{16,}/i, "[REDACTED]"},
    {~r/\bey[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/, "[REDACTED-JWT]"},
    {~r/(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token|private[_-]?key)(\s*[:=]\s*)\S+/,
     "\\1\\2[REDACTED]"}
  ]

  # Metadata worth keeping when an event has to be degraded: where a line came from, never what it
  # said. None of these can carry a credential.
  @safe_meta_keys [
    :time,
    :pid,
    :gl,
    :line,
    :file,
    :mfa,
    :module,
    :function,
    :application,
    :domain
  ]

  @doc """
  The filter. Returns the event with its message and metadata masked, never `:stop`, never raising.

  Never `:stop`, on purpose: a filter that drops a line to avoid printing a secret also drops the
  evidence that something happened. Masking keeps the event and removes the value.

  Never raising, also on purpose, and for a stronger reason: OTP removes a raising filter from the
  handler permanently, so one unexpected shape would disable redaction for the life of the node.
  Anything the walk cannot handle degrades to an event whose content is withheld.
  """
  @spec filter(map(), term()) :: map()
  def filter(%{msg: msg, meta: meta} = event, _opts) do
    %{event | msg: redact_msg(msg), meta: redact_meta(meta)}
  rescue
    e -> withheld(event, e)
  catch
    kind, reason -> withheld(event, {kind, reason})
  end

  def filter(event, _opts), do: event

  @doc """
  Masks credential-shaped substrings in a binary.

  A binary that is not valid UTF-8 is replaced rather than matched. The patterns cannot be applied
  to it (`Regex.replace/3` raises), it is not text a reader was meant to read, and bytes are the
  shape key material most often takes.
  """
  @spec redact(term()) :: term()
  def redact(text) when is_binary(text) do
    if String.valid?(text) do
      Enum.reduce(@patterns, text, fn {re, replacement}, acc ->
        Regex.replace(re, acc, replacement)
      end)
    else
      "[REDACTED-BINARY #{byte_size(text)} bytes]"
    end
  end

  def redact(other), do: other

  @doc "Truncates to the logging limit, saying how much was dropped rather than trailing off."
  @spec truncate(binary(), pos_integer()) :: binary()
  def truncate(text, max \\ @max_chars) when is_binary(text) do
    if String.valid?(text) and String.length(text) > max do
      String.slice(text, 0, max) <> "… [#{String.length(text) - max} more characters]"
    else
      text
    end
  end

  @doc "The character limit applied to a logged message."
  @spec max_chars() :: pos_integer()
  def max_chars, do: @max_chars

  # `{:string, chardata}` is flattened to a binary rather than walked element by element. A binary
  # is itself valid chardata, so nothing downstream can tell the difference, and it removes every
  # question about improper tails, nested lists and codepoints in one step. It must be matched
  # before the `{format, args}` clause below, which would otherwise catch it: an iolist is a list.
  defp redact_msg({:string, chardata}), do: {:string, chardata |> to_text() |> redact_text()}
  defp redact_msg({:report, report}), do: {:report, redact_term(report)}
  defp redact_msg({format, args}) when is_list(args), do: {format, redact_list(args)}
  defp redact_msg(other), do: other

  defp redact_meta(meta) when is_map(meta),
    do: Map.new(meta, fn {k, v} -> {k, redact_term(v)} end)

  defp redact_meta(meta), do: meta

  defp redact_term(v) when is_binary(v), do: redact_text(v)
  defp redact_term(v) when is_list(v), do: redact_list(v)
  defp redact_term(%{__struct__: _} = v), do: v
  defp redact_term(v) when is_map(v), do: Map.new(v, fn {k, val} -> {k, redact_term(val)} end)
  defp redact_term({a, b}), do: {redact_term(a), redact_term(b)}
  defp redact_term(v), do: v

  # The defect slice 125 exists for. `Enum.map/2` raises `FunctionClauseError` on an improper list,
  # and OTP chardata is routinely improper. This keeps the shape, tail and all, and redacts the
  # tail rather than walking off the end of it.
  defp redact_list([]), do: []
  defp redact_list([head | tail]), do: [redact_term(head) | redact_list(tail)]
  defp redact_list(tail), do: redact_term(tail)

  defp redact_text(text) when is_binary(text), do: text |> redact() |> truncate()

  # Chardata that `IO.chardata_to_string/1` refuses is still an event that has to be logged, so it
  # is inspected rather than dropped. `inspect/1` is total where the conversion is not.
  defp to_text(chardata) do
    IO.chardata_to_string(chardata)
  rescue
    _ -> inspect(chardata)
  catch
    _, _ -> inspect(chardata)
  end

  # The last line of the last line. Reached only if the walk above raised on something no test
  # anticipated, which is precisely when passing the event through unmasked would be worst.
  defp withheld(event, why) do
    reason = why |> inspect() |> binary_slice(0, @max_reason_chars)

    %{
      event
      | msg:
          {:string,
           "[REDACTED: this log event could not be filtered and its content is withheld. " <>
             "Reason: #{reason}]"},
        meta: safe_meta(event)
    }
  end

  defp safe_meta(%{meta: meta}) when is_map(meta), do: Map.take(meta, @safe_meta_keys)
  defp safe_meta(_), do: %{}
end
