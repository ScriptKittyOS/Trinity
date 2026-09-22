# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server do
  @moduledoc """
  Trinity as an MCP server (slice 061): the module above beam_mcp's core, handed to both of
  its transports through the `:server` option (ADR-0007 decision 6, shipped in beam_mcp
  0.9.0), implementing `BeamMCP.Server`. Every message but `tools/call` is the core's
  (`server/discover`, `initialize`, `tools/list` over `Trinity.MCP.Server.Catalog`, `ping` at
  the legacy era, every refusal); `tools/call` is answered here, because it is where authority
  lives: the arguments are validated by the core's validator against the listed schema, the
  call runs through `Trinity.Effects.Runner` in the MCP context (the `origin: "mcp"` session,
  the gate's decision receipted, the membrane for an `:artifact` tool), and the result is
  mapped to the wire at the era the request declared.

  The multi-round-trip pattern, for approvals: a call the gate holds for the owner is answered
  `input_required` with one elicitation request (which approval, and where to decide it) and
  a `requestState` sealed by `Trinity.MCP.Server.Envelope`; the retry opens the envelope,
  refuses one that is expired, tampered, replayed (`Trinity.MCP.Server.Replay`) or bound to
  another call, runs under the envelope's call id (so the approval the owner decided is the
  one consumed, and a second run is the membrane's duplicate), and answers `input_required`
  again while the owner has not decided, the result once allowed, an `isError` once denied.
  A 2025-11-25 client, whose revision has no `input_required`, is answered an `isError`
  naming the approval; its retry after the decision runs the same way. The core never sees
  any of it: will-not-implement entry 12 stands, and so does the layering the ADR chose.
  """
  @behaviour BeamMCP.Server

  alias Trinity.Effects
  alias Trinity.MCP.Server.{Envelope, Exports, Replay, Session}
  alias Trinity.MCP.Client.Wire
  alias Trinity.Tools.{Context, Result}

  @version_key "io.modelcontextprotocol/protocolVersion"
  @capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  @type state :: %{core: BeamMCP.Server.state(), server_name: String.t()}

  ## The behaviour

  @impl true
  def new(opts) do
    core = BeamMCP.Server.new(opts)
    %{core: core, server_name: Keyword.get(opts, :server_name, "trinity")}
  end

  @impl true
  def handle_message(
        %{core: core} = state,
        %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call"} = message
      )
      when not is_nil(id) do
    case era(core, message) do
      nil ->
        delegate(state, message)

      era ->
        params = Map.get(message, "params", %{})

        case {Map.get(params, "name"), Map.get(params, "arguments", %{})} do
          {name, args} when is_binary(name) and is_map(args) ->
            {state, answer(id, era, state, name, args, params)}

          _ ->
            delegate(state, message)
        end
    end
  end

  def handle_message(state, message), do: delegate(state, message)

  @impl true
  def shutdown?(%{core: core}), do: BeamMCP.Server.shutdown?(core)

  defp delegate(%{core: core} = state, message) do
    {core, response} = BeamMCP.Server.handle_message(core, message)
    {%{state | core: core}, response}
  end

  # The era the request declared, read as the core reads it: the `_meta` version (the modern
  # one needs the capabilities beside it, or the core's own refusal is the right answer), or
  # the legacy state an `initialize` set when the request carries no version. Anything else is
  # the core's to refuse, so this answers nil and the message is delegated.
  defp era(_core, %{"params" => %{"_meta" => %{@version_key => version} = meta}}) do
    cond do
      version == Wire.modern() and Map.has_key?(meta, @capabilities_key) -> :modern
      version == Wire.legacy() -> :legacy
      true -> nil
    end
  end

  defp era(%{initialized?: true}, %{"params" => params}) when not is_map_key(params, "_meta"),
    do: :legacy

  defp era(_core, _message), do: nil

  ## tools/call

  defp answer(id, era, state, name, args, params) do
    case Exports.entry(name) do
      nil ->
        result(id, era, state, tool_error("unknown tool #{name}"))

      entry ->
        with :ok <- validate(args, entry),
             {:ok, ctx, pending} <- context(name, args, params) do
          case pending do
            nil -> run(id, era, state, entry, args, ctx)
            approval_id -> approval_required(id, era, state, entry, args, ctx, approval_id)
          end
        else
          {:error, {:invalid_arguments, reason}} ->
            error(id, -32_602, "invalid arguments: #{reason}")

          {:error, {:state, reason}} ->
            error(id, -32_602, "requestState #{reason}")
        end
    end
  end

  defp validate(args, entry) do
    case Wire.validate_arguments(args, Trinity.Tools.Registry.schema(entry)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_arguments, reason}}
    end
  end

  # A first call runs under a fresh call id; a retry runs under the envelope's, once the
  # envelope opens and binds to this very call (tool and arguments), has not expired, and its
  # nonce has not been used on this instance. A retry whose approval the owner has not yet
  # decided does not reach the gate (it would mint a second request and mask the first): it
  # is held again, on the same approval, under a fresh envelope; the third element says so.
  defp context(name, args, params) do
    session = Session.row()
    trace = trace(params)

    case Map.get(params, "requestState") do
      nil ->
        {:ok, ctx(session, name, Trinity.UUID.generate(), trace), nil}

      state ->
        with {:ok, payload} <- open(state),
             :ok <- bound(payload, session.id, name, args),
             :ok <- unused(payload) do
          {:ok, ctx(session, name, payload.call_id, trace), pending(payload.approval_id)}
        end
    end
  end

  defp pending(approval_id) do
    case Trinity.Permissions.get_approval(approval_id) do
      %{status: "pending"} -> approval_id
      _ -> nil
    end
  end

  # The persona is the session's, as the Session process hands its tools (the memory tools
  # take the persona from the context and nowhere else).
  defp ctx(session, name, call_id, trace) do
    %Context{
      session_id: session.id,
      persona: session.persona_id && Trinity.Sessions.get_persona(session.persona_id),
      caller: "mcp",
      call_id: call_id,
      tool: name,
      origin: "mcp",
      trace: trace
    }
  end

  defp open(state) do
    case Envelope.open(state) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, {:state, Atom.to_string(reason)}}
    end
  end

  defp bound(payload, session_id, name, args) do
    if payload.session_id == session_id and payload.tool == name and
         payload.args_digest == Envelope.args_digest(args),
       do: :ok,
       else: {:error, {:state, "does not belong to this call"}}
  end

  defp unused(%{nonce: nonce, exp: exp}) do
    case Replay.use(nonce, exp) do
      :ok -> :ok
      {:error, :replayed} -> {:error, {:state, "already used"}}
    end
  end

  defp trace(%{"_meta" => meta}) when is_map(meta) do
    case Map.take(meta, ["traceparent", "tracestate"]) do
      m when map_size(m) == 0 -> nil
      m -> m
    end
  end

  defp trace(_), do: nil

  defp run(id, era, state, entry, args, ctx) do
    case Effects.Runner.run(%{id: ctx.call_id, name: entry.name, args: args}, ctx) do
      {:ok, %Result{} = r, _meta} ->
        result(id, era, state, tool_result(r))

      {:error, {:approval_required, approval_id}, _meta} ->
        approval_required(id, era, state, entry, args, ctx, approval_id)

      {:error, :denied, _meta} ->
        result(id, era, state, tool_error("denied: the owner refused this call"))

      {:error, reason, _meta} ->
        result(id, era, state, tool_error("the call failed: #{describe(reason)}"))
    end
  end

  # The hold, on the wire: at 2026-07-28 an `input_required` result with the sealed state; at
  # 2025-11-25 a tool error naming the approval, since that revision has no `input_required`.
  defp approval_required(id, :modern, state, entry, args, ctx, approval_id) do
    sealed =
      Envelope.seal(%{
        approval_id: approval_id,
        session_id: ctx.session_id,
        call_id: ctx.call_id,
        tool: entry.name,
        args_digest: Envelope.args_digest(args)
      })

    payload = %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "approval" => %{
          "method" => "elicitation/create",
          "params" => %{
            "mode" => "form",
            "message" =>
              "Trinity needs the owner's approval to run #{entry.name} (approval #{approval_id}). " <>
                "The owner decides on Trinity's permissions page; retry this call with the requestState once decided.",
            "requestedSchema" => %{
              "type" => "object",
              "properties" => %{
                "retry" => %{
                  "type" => "boolean",
                  "description" => "true to retry after the owner's decision"
                }
              }
            }
          }
        }
      },
      "requestState" => sealed,
      "_meta" => %{@server_info_key => server_info(state)}
    }

    %{"jsonrpc" => "2.0", "id" => id, "result" => payload}
  end

  defp approval_required(id, :legacy, state, entry, _args, _ctx, approval_id) do
    result(
      id,
      :legacy,
      state,
      tool_error(
        "approval required: the owner decides on Trinity's permissions page (approval #{approval_id}); " <>
          "retry #{entry.name} once decided"
      )
    )
  end

  ## The wire

  defp tool_result(%Result{content: content, meta: meta} = r) do
    base = %{
      "content" => [%{"type" => "text", "text" => Result.as_text(r)}],
      "isError" => meta["is_error"] == true
    }

    if is_map(content), do: Map.put(base, "structuredContent", content), else: base
  end

  defp tool_error(text),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}

  defp result(id, :modern, state, payload) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" =>
        payload
        |> Map.put("resultType", "complete")
        |> Map.put("_meta", %{@server_info_key => server_info(state)})
    }
  end

  defp result(id, :legacy, _state, payload),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => payload}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp server_info(%{server_name: name}),
    do: %{"name" => name, "version" => to_string(Application.spec(:trinity, :vsn))}

  # A reason a client may read: a word or two, never a term with Trinity's internals in it.
  defp describe(:timeout), do: "timed out"
  defp describe({:invalid_args, _}), do: "invalid arguments"
  defp describe({:crash, _}), do: "crashed"
  defp describe({:denied, {:duplicate_effect, _}}), do: "already run (duplicate effect)"
  defp describe(:approval_required), do: "approval required"
  defp describe({:request_failed, _}), do: "the approval could not be requested"
  defp describe(other) when is_atom(other), do: Atom.to_string(other)
  defp describe({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp describe(_), do: "error"
end
