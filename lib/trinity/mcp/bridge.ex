# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Bridge do
  @moduledoc """
  The one tool module every MCP tool runs through (slice 060). A server's listed tool is
  registered as a dynamic entry of `Trinity.Tools.Registry` with a spec (its name under
  `mcp:<server>:<tool>`, its description, its `inputSchema`, its effect and risk from the
  server's row) and this module; `execute/2` reads the entry's name from the context, calls
  the server through `Trinity.MCP.Client`, and hands back one untrusted result.

  The name is namespaced before any tier lookup, so a server cannot claim a core tool's
  tier (docs/07); the effect is `:none` unless the row says `:artifact` for the tool, and a
  row that claims `:catalog` is refused at load with a decision receipt on the server's
  chain scope, because the effect catalog is compile time and a server cannot enter it
  (AC3). The risk is `:ask` unless the row's override lowers it by name.

  A result whose `resultType` is `input_required` (the revision's multi-round-trip pattern)
  is not a result: the server's `inputRequests` become one approval-shaped request to the
  owner, the server's `requestState` is held verbatim beside the call, and the call is
  answered `{:error, {:approval_required, id}}`, which the Session holds and re-runs when
  the approval is decided. The re-run finds the continuation, reads the answer the decision
  carried, and sends the retry with `inputResponses` and the state untouched (docs/07).
  """
  @behaviour Trinity.Tools.Tool

  require Logger

  alias Trinity.MCP.{Client, ServerConfig}
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Tools.{Context, Result, Untrusted}

  @tool_name_pattern ~r/^[A-Za-z0-9_.-]{1,64}$/

  ## The behaviour: the spec supplies the definition; these are the defaults behind it.

  @impl true
  def name, do: "mcp:"
  @impl true
  def description, do: "A tool an MCP server contributes."
  @impl true
  def schema, do: %{"type" => "object"}
  @impl true
  def risk, do: :ask
  @impl true
  def effect, do: :none

  @doc "The registry name of a server's tool."
  @spec tool_name(String.t(), String.t()) :: String.t()
  def tool_name(server, tool), do: "mcp:" <> server <> ":" <> tool

  @doc "The chain scope a server's receipts go to."
  @spec scope(String.t()) :: String.t()
  def scope(server), do: "mcp:" <> server

  @doc """
  Registers a listed tool for a server. A name outside the pattern or a schema the registry
  cannot build is skipped and logged; an effect the row claims that the registry refuses
  (`catalog`) is refused with a decision receipt.
  """
  @spec register(ServerConfig.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def register(%ServerConfig{name: server} = config, tool, listed) when is_binary(tool) do
    registry_name = tool_name(server, tool)

    with :ok <- check_name(tool),
         {effect, risk} = classes(config, tool),
         spec = %{
           name: registry_name,
           description: to_string(Map.get(listed, "description") || ""),
           schema: Map.get(listed, "inputSchema") || %{"type" => "object"},
           effect: effect,
           risk: risk
         },
         {:ok, _entry} <- Trinity.Tools.register(__MODULE__, spec: spec) do
      {:ok, registry_name}
    else
      {:error, reason} = error ->
        refused(config, tool, registry_name, reason)
        error
    end
  end

  @doc "Removes a registered tool."
  @spec unregister(String.t()) :: :ok | {:error, term()}
  def unregister(registry_name), do: Trinity.Tools.unregister(registry_name)

  defp check_name(tool) do
    if Regex.match?(@tool_name_pattern, tool), do: :ok, else: {:error, {:invalid_tool_name, tool}}
  end

  # The row's classes for a tool: the override's effect and risk when named, the row's
  # default effect otherwise, `:ask` for the risk. The strings are the row's; an unknown one
  # is passed through for the registry to refuse (`catalog` included), never mapped to a
  # safe value silently.
  defp classes(%ServerConfig{effect_default: default, tool_overrides: overrides}, tool) do
    override = Map.get(overrides || %{}, tool, %{})
    effect = Map.get(override, "effect") || default
    risk = Map.get(override, "risk") || "ask"
    {as_atom(effect), as_atom(risk)}
  end

  defp as_atom(s) when is_binary(s), do: String.to_existing_atom(s)
  defp as_atom(a) when is_atom(a), do: a

  # A refusal at load is a decision receipt of outcome deny on the server's scope: the
  # tool is not registered, and the record says which and why.
  defp refused(%ServerConfig{name: server}, tool, registry_name, reason) do
    Logger.warning("mcp #{server}: tool #{tool} not registered: #{inspect(reason)}")

    Receipts.append(scope(server), %{
      kind: "decision",
      subject: %{"server" => server, "tool" => registry_name, "phase" => "load"},
      decision: %{"outcome" => "deny", "basis" => "registry", "reason" => inspect(reason)},
      subject_ref: "mcp-load:" <> registry_name,
      meta: %{}
    })
  end

  ## Executing

  @impl true
  def execute(args, %Context{tool: "mcp:" <> rest} = ctx) do
    case String.split(rest, ":", parts: 2) do
      [server, tool] -> run(server, tool, args, ctx)
      _ -> {:error, {:unknown_tool, ctx.tool}}
    end
  end

  def execute(_args, %Context{tool: other}), do: {:error, {:unknown_tool, other}}

  defp run(server, tool, args, ctx) do
    key = {ctx.session_id, ctx.call_id}

    opts =
      case Client.pop_continuation(server, key) do
        nil -> []
        continuation -> [continuation: continued(continuation)]
      end

    case Client.call(server, tool, args, opts) do
      {:ok, %{"result" => %{"resultType" => "input_required"} = result}} ->
        hold(server, tool, args, ctx, key, result)

      {:ok, %{"result" => result}} when is_map(result) ->
        {:ok, to_result(server, tool, ctx.tool, result)}

      {:ok, %{"error" => %{"code" => code, "message" => message}}} ->
        {:error, {:server_error, code, message}}

      {:ok, other} ->
        {:error, {:unreadable_answer, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The continuation stored at the hold, joined with the answer the decision carried: the
  # `inputResponses` map keyed as the server's `inputRequests` were, and the state verbatim.
  defp continued(%{state: state, approval_id: id}) do
    answer =
      case Permissions.get_approval(id) do
        %{answer: %{} = answer} -> answer
        _ -> %{}
      end

    %{responses: answer, state: state}
  end

  # The server's requests become one approval for the owner, with the same fingerprint the
  # running call has (same session, name, arguments, cwd), so the decision the owner makes
  # is the one the re-run consumes. The state is held here and never in the row.
  defp hold(server, _tool, args, ctx, key, result) do
    requests = Map.get(result, "inputRequests") || %{}
    state = Map.get(result, "requestState")

    request = %{
      "kind" => "mcp_input",
      "server" => server,
      "inputRequests" => requests
    }

    case Permissions.request_approval(ctx.session_id, ctx.tool, args,
           cwd: ctx.cwd,
           risk: :ask,
           request: request
         ) do
      {:ok, approval} ->
        :ok = Client.put_continuation(server, key, %{state: state, approval_id: approval.id})
        {:error, {:approval_required, approval.id}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  ## Results

  # Text parts joined; an image or audio part is a line naming its type and size (the
  # bytes are not handed to the model); an embedded resource is its text or a line naming
  # its uri. `isError` rides in the meta and prefixes the text, so the model reads it as the
  # server's error and not as content.
  defp to_result(server, tool, registry_name, result) do
    parts = Map.get(result, "content") || []
    text = parts |> Enum.map(&part_text/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
    error? = Map.get(result, "isError") == true

    text =
      cond do
        error? and text == "" ->
          "[the server reported an error]"

        error? ->
          "[the server reported an error]\n" <> text

        text == "" and is_map(Map.get(result, "structuredContent")) ->
          Jason.encode!(result["structuredContent"])

        true ->
          text
      end

    Untrusted.result(text,
      tool: registry_name,
      source_ref: "mcp://" <> server <> "/" <> tool,
      meta: %{"server" => server, "tool" => tool, "is_error" => error?, "parts" => length(parts)}
    )
  end

  defp part_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  defp part_text(%{"type" => type, "data" => data} = part)
       when type in ["image", "audio"] and is_binary(data),
       do:
         "[#{type}: #{byte_size(data)} bytes of base64, #{Map.get(part, "mimeType", "unknown type")}]"

  defp part_text(%{"type" => "resource", "resource" => %{"text" => text}}) when is_binary(text),
    do: text

  defp part_text(%{"type" => "resource", "resource" => %{"uri" => uri}}) when is_binary(uri),
    do: "[resource: #{uri}]"

  defp part_text(%{"type" => "resource_link", "uri" => uri}) when is_binary(uri),
    do: "[resource: #{uri}]"

  defp part_text(_), do: ""

  @impl true
  def format_result(%Result{} = result), do: Result.as_text(result)
end
