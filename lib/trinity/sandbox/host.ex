# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox.Host do
  @moduledoc """
  What a script inside the sandbox can reach (slice 110).

  The sandbox removes the machine; this puts back a named, small surface, and every effect on it
  goes through the ordinary path. `trinity.tool/2` calls `Trinity.Effects.Runner.execute/3`, the
  same executor a model's tool call uses, so a call made from Lua is decided by the same gate,
  crosses the same membrane and leaves the same receipts. There is no second door.

  ## A script cannot wait for a person, and says so rather than hanging

  A sandboxed run is bounded in wall clock, typically a second. A permission decision of `:ask`
  raises an approval a human answers in their own time. Those cannot both be true, so a call that
  needs approval returns an error value to Lua **immediately** rather than blocking until the run's
  clock kills it. The script can handle it; what it cannot do is hold the sandbox open waiting.

  This is a real limit and it is the honest one: the alternative, letting a script block, would
  turn every approval into a timeout and teach the owner that sandbox runs fail at random.

  ## Errors are values

  Lua's idiom for a failing call is `nil, message`, and that is what these return. A host function
  that raised into the interpreter would abort the script at the call site and lose whatever it had
  already computed, which is the wrong shape for "the gate said no".
  """

  # No `use Boundary`: a module nested under `Trinity.Sandbox` belongs to that boundary already.

  alias Trinity.Effects
  alias Trinity.Tools
  alias Trinity.Tools.Context

  @log_key :trinity_sandbox_log
  @result_key :trinity_sandbox_result
  @max_log_entries 200
  @max_log_bytes 8_000

  @doc "Installs the host surface into a Luerl state for the session `ctx` describes."
  @spec install(term(), Context.t()) :: {:ok, term()} | {:error, term()}
  def install(state, %Context{} = ctx) do
    with {:ok, state} <- set(state, "trinity", trinity_table(ctx)) do
      set(state, "json", json_table())
    end
  end

  @doc "The log lines a finished run produced, oldest first."
  @spec log() :: [String.t()]
  def log, do: Process.get(@log_key, []) |> Enum.reverse()

  @doc "The structured result a run declared with `trinity.result`, or nil."
  @spec result() :: term()
  def result, do: Process.get(@result_key)

  @doc "Clears the per-run accumulators. The runner calls this; nothing else should need to."
  @spec reset() :: :ok
  def reset do
    Process.delete(@log_key)
    Process.delete(@result_key)
    :ok
  end

  defp trinity_table(ctx) do
    [
      {"tool", fn args, state -> tool(args, state, ctx) end},
      {"log", &log_line/2},
      {"result", &set_result/2}
    ]
  end

  defp json_table do
    [
      {"encode", &json_encode/2},
      {"decode", &json_decode/2}
    ]
  end

  ## trinity.tool

  defp tool([name | rest], state, ctx) when is_binary(name) do
    args = decode_args(rest, state)

    case Tools.lookup(name) do
      {:ok, entry} -> run_tool(entry, args, ctx, state)
      {:error, reason} -> lua_error(state, "unknown tool #{name}: #{inspect(reason)}")
    end
  end

  defp tool(_other, state, _ctx),
    do: lua_error(state, "trinity.tool(name, args): the first argument must be a tool name")

  defp run_tool(entry, args, ctx, state) do
    case Effects.Runner.execute(entry, args, %{ctx | tool: entry.name}) do
      {:ok, result} ->
        encode_result(result, state)

      {:error, {:approval_required, _} = reason} ->
        lua_error(state, approval_message(reason))

      {:error, reason} ->
        lua_error(state, "refused: #{inspect(reason)}")
    end
  end

  defp approval_message(_reason) do
    "approval required: this call needs a person to decide, and a sandboxed run cannot wait for " <>
      "one. Ask for it outside the sandbox, or have the owner write a rule."
  end

  defp encode_result(%{content: content}, state) when is_binary(content) do
    {[content], state}
  end

  defp encode_result(result, state) do
    {value, state} = :luerl.encode(inspect(result), state)
    {[value], state}
  end

  ## trinity.log and trinity.result

  defp log_line([message | _], state) do
    line = message |> to_string() |> String.slice(0, @max_log_bytes)
    existing = Process.get(@log_key, [])

    if length(existing) < @max_log_entries do
      Process.put(@log_key, [line | existing])
    end

    {[], state}
  end

  defp log_line(_, state), do: {[], state}

  defp set_result([table | _], state) do
    Process.put(@result_key, :luerl.decode(table, state))
    {[], state}
  end

  defp set_result(_, state), do: {[], state}

  ## json

  defp json_encode([value | _], state) do
    decoded = :luerl.decode(value, state)

    case Jason.encode(to_json(decoded)) do
      {:ok, json} -> {[json], state}
      {:error, reason} -> lua_error(state, "json.encode: #{inspect(reason)}")
    end
  end

  defp json_encode(_, state), do: lua_error(state, "json.encode(value)")

  defp json_decode([json | _], state) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, term} ->
        {value, state} = :luerl.encode(from_json(term), state)
        {[value], state}

      {:error, _} ->
        lua_error(state, "json.decode: not valid JSON")
    end
  end

  defp json_decode(_, state), do: lua_error(state, "json.decode(string)")

  # Luerl decodes every table to a proplist, so an array arrives as [{1, v}, {2, v}]. JSON needs to
  # know which it is, and the rule Lua itself uses is the only one available: consecutive integer
  # keys from one is a list, anything else is an object.
  defp to_json(list) when is_list(list) do
    if array?(list) do
      Enum.map(list, fn {_i, v} -> to_json(v) end)
    else
      Map.new(list, fn {k, v} -> {to_string(k), to_json(v)} end)
    end
  end

  defp to_json(other), do: other

  defp array?([]), do: true

  defp array?(list) do
    Enum.with_index(list, 1)
    |> Enum.all?(fn {{k, _v}, i} -> k == i end)
  end

  defp from_json(map) when is_map(map), do: Enum.map(map, fn {k, v} -> {k, from_json(v)} end)

  defp from_json(list) when is_list(list),
    do: Enum.with_index(list, 1) |> Enum.map(fn {v, i} -> {i, from_json(v)} end)

  defp from_json(other), do: other

  ## helpers

  defp set(state, key, pairs) do
    case :luerl.set_table_keys_dec([key], pairs, state) do
      {:ok, state} -> {:ok, state}
      other -> {:error, other}
    end
  end

  defp decode_args([table | _], state) do
    case :luerl.decode(table, state) do
      pairs when is_list(pairs) -> Map.new(pairs, fn {k, v} -> {to_string(k), v} end)
      _ -> %{}
    end
  end

  defp decode_args(_, _state), do: %{}

  # `nil, message` is Lua's own idiom for a failing call, and it keeps the script running so it can
  # decide what to do. Raising would abort at the call site and discard whatever it had computed.
  defp lua_error(state, message), do: {[nil, message], state}
end
