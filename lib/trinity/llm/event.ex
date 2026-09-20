# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Event do
  @moduledoc """
  The event stream shape every provider emits and every consumer reads. Slice 011.

  Seven shapes, from SLICE.md, and nothing else. Slice 012's Session and slice 013's UI consume
  these and never a provider's own chunks; `valid?/1` is the guard a provider's output is
  held to in tests.
  """

  @type tool_call_id :: String.t()
  @type t ::
          {:text_delta, String.t()}
          | {:tool_call_start, tool_call_id(), name :: String.t()}
          | {:tool_call_delta, tool_call_id(), json_chunk :: String.t()}
          | {:tool_call_end, tool_call_id(), args :: map()}
          | {:usage, map()}
          | {:done, reason :: :stop | :length | :tool_calls | :content_filter | atom()}
          | {:error, term()}

  @doc "True for exactly the seven shapes above."
  @spec valid?(term()) :: boolean()
  def valid?({:text_delta, s}) when is_binary(s), do: true
  def valid?({:tool_call_start, id, name}) when is_binary(id) and is_binary(name), do: true
  def valid?({:tool_call_delta, id, chunk}) when is_binary(id) and is_binary(chunk), do: true
  def valid?({:tool_call_end, id, args}) when is_binary(id) and is_map(args), do: true
  def valid?({:usage, usage}) when is_map(usage), do: true
  def valid?({:done, reason}) when is_atom(reason), do: true
  def valid?({:error, _}), do: true
  def valid?(_), do: false
end
