# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Session do
  @moduledoc """
  One conversation, one `gen_statem`. Slice 012.

  States: `idle`, `thinking` (a model call streaming in a Task), `tool_wait` (tool calls running
  in a Task), `approval_wait` and `compacting` (present for the machine's shape; nothing enters
  them until slices 021 and 023), `error` (a failed turn, recorded, then back to `idle`).

  Rules this process keeps: every durable change is a row before it is a broadcast; the model
  and the tools run in Tasks under the session's own supervisor and talk back only by message;
  a draft of the assistant's text is persisted every 500 ms or 2 KB so a kill mid-turn loses at
  most that much and the row is marked interrupted on the next init; caps are code
  (`Trinity.Sessions.Caps`) and reaching one is a normal return to `idle`; the sentinel's
  findings only ever tighten.
  """
  @behaviour :gen_statem

  require Logger

  alias Trinity.LLM
  alias Trinity.Sessions.{Caps, Events, Prompt, Sentinel, State, Store, ToolRunner}

  @coalesce_ms 50
  @draft_ms 500
  @draft_bytes 2_048

  ## API

  @spec start_link(String.t()) :: :gen_statem.start_ret()
  def start_link(session_id) do
    :gen_statem.start_link(via(session_id), __MODULE__, session_id, [])
  end

  @spec via(String.t()) :: {:via, Registry, {Trinity.Registry, String.t()}}
  def via(session_id), do: {:via, Registry, {Trinity.Registry, session_id}}

  @doc "Persists the user's message, broadcasts it, and starts a turn. Busy sessions refuse."
  @spec send_user_message(pid() | String.t(), String.t()) ::
          {:ok, Store.message()} | {:error, term()}
  def send_user_message(ref, content), do: :gen_statem.call(target(ref), {:user_message, content})

  @doc "Stops the turn in flight, persisting what arrived as interrupted."
  @spec cancel_turn(pid() | String.t()) :: :ok | {:error, :idle}
  def cancel_turn(ref), do: :gen_statem.call(target(ref), :cancel)

  @doc "The state name and a redacted view of the data: no grants, approvals or pending calls hide here."
  @spec state(pid() | String.t()) :: %{
          state: atom(),
          pending: [map()],
          turns: non_neg_integer(),
          draft_id: String.t() | nil
        }
  def state(ref), do: :gen_statem.call(target(ref), :state)

  defp target(pid) when is_pid(pid), do: pid
  defp target(id) when is_binary(id), do: via(id)

  ## gen_statem

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(session_id) do
    case Store.get_session(session_id) do
      nil ->
        {:stop, {:no_session, session_id}}

      session ->
        Process.flag(:trap_exit, true)
        {:ok, task_sup} = Task.Supervisor.start_link()
        data = %State{id: session_id, session: session, turn: nil, task_sup: task_sup}
        {:ok, :idle, data, [{:next_event, :internal, :rehydrate}]}
    end
  end

  # A draft left behind by a previous incarnation is a turn that was cut short: mark it and say so.
  @impl true
  def handle_event(:internal, :rehydrate, :idle, %State{id: id}) do
    case Store.latest_draft(id) do
      nil ->
        :keep_state_and_data

      draft ->
        {:ok, interrupted} =
          Store.finalize_message(draft, %{
            parts: Map.merge(draft.parts, %{"draft" => false, "interrupted" => true})
          })

        Events.broadcast(id, {:turn_interrupted, interrupted})
        :keep_state_and_data
    end
  end

  def handle_event(:enter, _old, state, %State{id: id}) do
    Events.broadcast(id, {:state, state})

    case state do
      :idle ->
        {:keep_state_and_data, idle_timers()}

      :error ->
        {:keep_state_and_data, [{:state_timeout, 0, :recover}]}

      _ ->
        {:keep_state_and_data, [{{:timeout, :hibernate}, :cancel}, {{:timeout, :stop}, :cancel}]}
    end
  end

  def handle_event({:timeout, :hibernate}, :hibernate, :idle, _data),
    do: {:keep_state_and_data, [:hibernate]}

  def handle_event({:timeout, :stop}, :stop, :idle, _data), do: {:stop, :normal}

  def handle_event(:state_timeout, :recover, :error, data),
    do: {:next_state, :idle, %{data | turn: nil}}

  def handle_event({:call, from}, :state, state, %State{turn: turn}) do
    view = %{
      state: state,
      pending: (turn && turn.pending) || [],
      turns: (turn && turn.turns) || 0,
      draft_id: turn && turn.draft_id
    }

    {:keep_state_and_data, [{:reply, from, view}]}
  end

  def handle_event({:call, from}, {:user_message, content}, :idle, %State{id: id} = data) do
    case Trinity.Sessions.append_message(id, %{role: "user", content: content}) do
      {:ok, message} ->
        Events.broadcast(id, {:user_message, message})
        data = %{data | turn: State.new_turn()}
        {:next_state, :thinking, start_model_call(data), [{:reply, from, {:ok, message}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:user_message, _}, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, {:busy, state}}}]}
  end

  def handle_event({:call, from}, :cancel, state, %State{} = data)
      when state in [:thinking, :tool_wait] do
    kill_task(data)
    data = flush_deltas(data)
    data = persist_final(data, %{"interrupted" => true})
    {:next_state, :idle, %{data | turn: nil}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :cancel, _state, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :idle}}]}

  # Model events arrive as messages from the streaming Task.
  def handle_event(:info, {:llm_event, ref, event}, :thinking, %State{turn: %{ref: ref}} = data) do
    {:keep_state, fold_event(event, data)}
  end

  def handle_event(:info, {:llm_done, ref, result}, :thinking, %State{turn: %{ref: ref}} = data) do
    data = flush_deltas(data)

    case result do
      {:ok, usage} -> finish_turn(%{data | turn: Map.put(data.turn, :usage, usage)})
      {:error, reason} -> fail_turn(data, reason)
    end
  end

  def handle_event(:info, :coalesce, :thinking, data),
    do: {:keep_state, flush_deltas(%{data | turn: %{data.turn | coalesce_timer: nil}})}

  # Tool results arrive from the tool Task.
  def handle_event(
        :info,
        {:tools_done, ref, results},
        :tool_wait,
        %State{turn: %{ref: ref}} = data
      ) do
    data = record_tool_results(data, results)
    turn = %{data.turn | pending: [], turns: data.turn.turns + 1}
    data = %{data | turn: turn}

    case Caps.check(turn) do
      :ok -> {:next_state, :thinking, start_model_call(data)}
      {:cap, reason} -> cap_reached(data, reason)
    end
  end

  # The Task died: a crash is an error turn, an ordinary exit after its message is nothing.
  def handle_event(
        :info,
        {:DOWN, _mon, :process, pid, reason},
        state,
        %State{turn: %{task: pid}} = data
      )
      when state in [:thinking, :tool_wait] and reason != :normal do
    fail_turn(data, {:task_down, reason})
  end

  def handle_event(:info, {:DOWN, _, :process, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:EXIT, _pid, _reason}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:llm_event, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:llm_done, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, :coalesce, _state, _data), do: :keep_state_and_data
  def handle_event(:info, _other, _state, _data), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _state, _data), do: :ok

  ## The turn

  defp start_model_call(%State{id: id, session: session, task_sup: sup, turn: turn} = data) do
    persona = session.persona_id && Store.get_persona(session.persona_id)
    request = Prompt.build(session, persona, Trinity.Sessions.history(id, limit: 500))
    ref = make_ref()
    me = self()

    %Task{pid: pid} =
      Task.Supervisor.async_nolink(sup, fn ->
        result = LLM.stream(request, [session_id: id], &send(me, {:llm_event, ref, &1}))
        send(me, {:llm_done, ref, result})
      end)

    %{data | turn: %{turn | ref: ref, task: pid, buffer: [], text: "", pending: [], finish: nil}}
  end

  defp fold_event({:text_delta, s}, %State{turn: turn} = data) do
    turn = %{
      turn
      | buffer: [turn.buffer, s],
        text: turn.text <> s,
        draft_bytes_since: turn.draft_bytes_since + byte_size(s)
    }

    data = %{data | turn: turn}
    data = if turn.coalesce_timer, do: data, else: arm_coalesce(data)
    maybe_persist_draft(data)
  end

  defp fold_event({:tool_call_start, id, name}, %State{id: sid, turn: turn} = data) do
    Events.broadcast(sid, {:tool_call, %{id: id, name: name}})
    %{data | turn: %{turn | pending: turn.pending ++ [%{id: id, name: name, args: %{}}]}}
  end

  defp fold_event({:tool_call_end, id, args}, %State{turn: turn} = data) do
    pending = Enum.map(turn.pending, fn c -> if c.id == id, do: %{c | args: args}, else: c end)

    pending =
      if Enum.any?(pending, &(&1.id == id)),
        do: pending,
        else: pending ++ [%{id: id, name: "", args: args}]

    %{data | turn: %{turn | pending: pending}}
  end

  defp fold_event({:usage, usage}, %State{turn: turn} = data) do
    tokens = Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
    %{data | turn: %{turn | usage: usage, tokens: turn.tokens + tokens}}
  end

  defp fold_event({:done, reason}, %State{turn: turn} = data),
    do: %{data | turn: %{turn | finish: reason}}

  defp fold_event({:error, _reason}, data), do: data
  defp fold_event(_, data), do: data

  defp arm_coalesce(%State{turn: turn} = data) do
    %{data | turn: %{turn | coalesce_timer: Process.send_after(self(), :coalesce, @coalesce_ms)}}
  end

  defp flush_deltas(%State{turn: nil} = data), do: data

  defp flush_deltas(%State{id: id, turn: turn} = data) do
    case IO.iodata_to_binary(turn.buffer) do
      "" -> data
      text -> Events.broadcast(id, {:assistant_delta, text})
    end

    if turn.coalesce_timer, do: Process.cancel_timer(turn.coalesce_timer)
    %{data | turn: %{turn | buffer: [], coalesce_timer: nil}}
  end

  # A draft row is written every @draft_ms or @draft_bytes, whichever first, and finalised at the
  # end of the turn; a kill in between loses at most that much text.
  defp maybe_persist_draft(%State{turn: turn} = data) do
    now = System.monotonic_time(:millisecond)

    if turn.text != "" and
         (now - turn.last_draft_at >= @draft_ms or turn.draft_bytes_since >= @draft_bytes) do
      data = write_draft(data)
      %{data | turn: %{data.turn | last_draft_at: now, draft_bytes_since: 0}}
    else
      data
    end
  end

  defp write_draft(%State{id: id, turn: %{draft_id: nil} = turn} = data) do
    case Trinity.Sessions.append_message(id, %{
           role: "assistant",
           content: turn.text,
           parts: %{"draft" => true}
         }) do
      {:ok, m} -> %{data | turn: %{turn | draft_id: m.id}}
      {:error, _} -> data
    end
  end

  defp write_draft(%State{turn: %{draft_id: draft_id} = turn} = data) do
    case Store.get_message(draft_id) do
      nil -> data
      m -> Store.finalize_message(m, %{content: turn.text}) && %{data | turn: turn}
    end
  end

  # The assistant row: the draft finalised, or inserted now if no draft was written yet.
  defp persist_final(%State{turn: nil} = data, _extra), do: data

  defp persist_final(%State{id: id, turn: turn} = data, extra) do
    findings =
      Sentinel.merge(
        turn.sentinel,
        Sentinel.preflight(turn.text) ++ Sentinel.loop_abuse(turn.pending)
      )

    calls = Enum.map(turn.pending, &%{"id" => &1.id, "name" => &1.name, "args" => &1.args})

    parts =
      %{"draft" => false, "tool_calls" => calls}
      |> Map.merge(extra)

    meta = %{
      "sentinel" =>
        Enum.map(findings, &%{"kind" => Atom.to_string(&1.kind), "match" => &1.match}),
      "outcome" => Atom.to_string(Sentinel.outcome(findings))
    }

    meta = if turn.finish, do: Map.put(meta, "finish", Atom.to_string(turn.finish)), else: meta
    content = if turn.text == "", do: "(no text)", else: turn.text

    result =
      case turn.draft_id && Store.get_message(turn.draft_id) do
        nil ->
          Trinity.Sessions.append_message(id, %{
            role: "assistant",
            content: content,
            parts: parts,
            usage: stringify(turn.usage),
            provider_meta: meta
          })

        draft ->
          Store.finalize_message(draft, %{
            content: content,
            parts: parts,
            usage: stringify(turn.usage),
            provider_meta: meta
          })
      end

    case result do
      {:ok, message} ->
        Events.broadcast(id, message_event(message, extra))
        %{data | turn: %{turn | sentinel: findings, draft_id: message.id}}

      {:error, reason} ->
        Logger.error("session #{id}: could not persist the assistant message: #{inspect(reason)}")
        data
    end
  end

  defp message_event(message, %{"interrupted" => true}), do: {:turn_interrupted, message}
  defp message_event(message, _), do: {:assistant_message, message}

  defp finish_turn(%State{turn: turn} = data) do
    case {turn.finish, turn.pending} do
      {:tool_calls, [_ | _]} ->
        data = persist_final(data, %{})
        {:next_state, :tool_wait, start_tools(data)}

      _ ->
        data = persist_final(data, %{})
        {:next_state, :idle, %{data | turn: nil}}
    end
  end

  defp start_tools(%State{id: id, task_sup: sup, turn: turn} = data) do
    ref = make_ref()
    me = self()
    calls = turn.pending

    %Task{pid: pid} =
      Task.Supervisor.async_nolink(sup, fn ->
        results = Enum.map(calls, fn call -> {call, ToolRunner.run(call, %{session_id: id})} end)
        send(me, {:tools_done, ref, results})
      end)

    %{
      data
      | turn: %{turn | ref: ref, task: pid, draft_id: nil, buffer: [], text: "", finish: nil}
    }
  end

  defp record_tool_results(%State{id: id} = data, results) do
    Enum.each(results, fn {call, result} ->
      content =
        case result do
          {:ok, text} -> text
          {:error, reason} -> "error: #{inspect(reason)}"
        end

      {:ok, _} =
        Trinity.Sessions.append_message(id, %{
          role: "tool",
          content: content,
          tool_call_id: call.id,
          parts: %{"tool" => call.name, "ok" => match?({:ok, _}, result)}
        })
    end)

    data
  end

  defp cap_reached(%State{id: id, turn: turn} = data, reason) do
    Logger.info("session #{id}: cap reached: #{reason}")

    data = %{
      data
      | turn: %{turn | text: "(stopped: #{reason} reached)", pending: [], finish: :cap}
    }

    data = persist_final(data, %{"cap" => Atom.to_string(reason)})
    {:next_state, :idle, %{data | turn: nil}}
  end

  defp fail_turn(%State{id: id, turn: turn} = data, reason) do
    kill_task(data)
    data = flush_deltas(data)
    Events.broadcast(id, {:error, reason})

    data = %{
      data
      | turn: %{
          turn
          | text: (turn.text == "" && "(error: #{inspect(reason)})") || turn.text,
            pending: []
        }
    }

    data = persist_final(data, %{"error" => inspect(reason)})
    {:next_state, :error, %{data | turn: nil}}
  end

  defp kill_task(%State{task_sup: sup, turn: %{task: pid}}) when is_pid(pid) do
    Task.Supervisor.terminate_child(sup, pid)
    :ok
  end

  defp kill_task(_), do: :ok

  defp idle_timers do
    cfg = Application.get_env(:trinity, :sessions, [])

    [
      {{:timeout, :hibernate}, Keyword.get(cfg, :idle_hibernate_ms, 300_000), :hibernate},
      {{:timeout, :stop}, Keyword.get(cfg, :idle_stop_ms, 3_600_000), :stop}
    ]
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
