# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Session do
  @moduledoc """
  One conversation, one `gen_statem`. Slice 012.

  States: `idle`, `thinking` (a model call streaming in a Task), `tool_wait` (tool calls running
  in a Task), `approval_wait` (slice 021: calls the gate holds until the owner decides),
  `compacting` (slice 023: the history summarised in a Task before the model call, when the
  request's estimate is over the model's soft threshold), `error` (a failed turn, recorded,
  then back to `idle`).

  Rules this process keeps: every durable change is a row before it is a broadcast; the model
  and the tools run in Tasks under the session's own supervisor and talk back only by message;
  a draft of the assistant's text is persisted every 500 ms or 2 KB so a kill mid-turn loses at
  most that much and the row is marked interrupted on the next init; caps are code
  (`Trinity.Sessions.Caps`) and reaching one is a normal return to `idle`; the sentinel's
  findings only ever tighten.
  """
  @behaviour :gen_statem

  require Logger

  alias Trinity.Content.Part
  alias Trinity.LLM
  alias Trinity.Memory.{Compactor, Tokens}
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

  @doc """
  The state name and a redacted view of the data: no grants, approvals or pending calls hide
  here. `text` is the in-progress assistant text (slice 013 reads it when a page mounts
  mid-stream); it is empty outside a turn.
  """
  @spec state(pid() | String.t()) :: %{
          state: atom(),
          pending: [map()],
          turns: non_neg_integer(),
          draft_id: String.t() | nil,
          text: String.t()
        }
  def state(ref), do: :gen_statem.call(target(ref), :state)

  @doc "Recomputes the always-on memory snapshot the next turn will carry (slice 030); returns it."
  @spec refresh_memory(pid() | String.t()) :: {:ok, String.t()}
  def refresh_memory(ref), do: :gen_statem.call(target(ref), :refresh_memory)

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
        # Slice 021: the gate's decisions for this session's requests arrive here.
        :ok = Trinity.Permissions.subscribe(session_id)
        {:ok, task_sup} = Task.Supervisor.start_link()

        data = %State{
          id: session_id,
          session: session,
          turn: nil,
          task_sup: task_sup,
          memory: memory_snapshot(session)
        }

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

  def handle_event(:enter, old, state, %State{id: id}) do
    Events.broadcast(id, {:state, state})
    # Slice 090: the transition, with no conversation content in it.
    Trinity.Telemetry.session_transition(id, old, state)

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

  # Slice 030: the snapshot is recomputed only here; the next turn reads the new one.
  def handle_event({:call, from}, :refresh_memory, _state, %State{session: session} = data) do
    memory = memory_snapshot(session)
    {:keep_state, %{data | memory: memory}, [{:reply, from, {:ok, memory}}]}
  end

  def handle_event({:call, from}, :state, state, %State{turn: turn}) do
    view = %{
      state: state,
      pending: (turn && turn.pending) || [],
      turns: (turn && turn.turns) || 0,
      draft_id: turn && turn.draft_id,
      text: (turn && turn.text) || ""
    }

    {:keep_state_and_data, [{:reply, from, view}]}
  end

  def handle_event({:call, from}, {:user_message, content}, :idle, %State{id: id} = data) do
    case Trinity.Sessions.append_message(id, %{role: "user", content: content}) do
      {:ok, message} ->
        Events.broadcast(id, {:user_message, message})
        data = %{data | turn: State.new_turn()}

        case start_turn(data) do
          {:forking, data} ->
            {:next_state, next, data} = fork(data, Trinity.Sessions.history(id, limit: 500))
            {:next_state, next, data, [{:reply, from, {:ok, message}}]}

          {state, data} ->
            {:next_state, state, data, [{:reply, from, {:ok, message}}]}
        end

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:user_message, _}, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, {:busy, state}}}]}
  end

  def handle_event({:call, from}, :cancel, state, %State{} = data)
      when state in [:thinking, :tool_wait, :approval_wait, :compacting] do
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

  # Tool results arrive from the tool Task. A result that asks for an approval (slice 021)
  # holds its call: the row is the gate's, the Session waits in approval_wait, and the held
  # calls run again once every decision is in.
  def handle_event(
        :info,
        {:tools_done, ref, results},
        :tool_wait,
        %State{turn: %{ref: ref}} = data
      ) do
    {held, done} =
      Enum.split_with(results, &match?({_, {:error, {:approval_required, _}, _}}, &1))

    data = record_tool_results(data, done)

    case held do
      [] ->
        next_turn(data)

      _ ->
        awaiting =
          Map.new(held, fn {call, {:error, {:approval_required, id}, _}} -> {id, call} end)

        {:next_state, :approval_wait,
         %{data | turn: %{data.turn | awaiting: awaiting, task: nil}}}
    end
  end

  def handle_event(
        :info,
        {:approval, :decided, %{id: id}},
        :approval_wait,
        %State{turn: %{awaiting: awaiting}} = data
      )
      when is_map_key(awaiting, id) do
    # A decided request is still a held call: whether it runs or is refused is the policy's
    # answer at execution, where the fingerprint is re-derived.
    {call, rest} = Map.pop(awaiting, id)
    turn = %{data.turn | awaiting: rest, held: data.turn.held ++ [call]}
    data = %{data | turn: turn}

    if rest == %{} do
      {:next_state, :tool_wait, start_tools(data, turn.held)}
    else
      {:keep_state, data}
    end
  end

  # A decision that arrives while the tools are still running: the gate broadcasts the request
  # from inside the runner, before the runner returns, so the owner can decide before this
  # process has entered approval_wait. Postponed, gen_statem redelivers it on the next state
  # change, where the clause above takes it. Found at slice 024 (the decision receipt widened
  # the window from microseconds to a fsync) and seen once by chance at slice 003's close
  # (its NOTES finding 11): a fix to slice 021's design, not to this slice's.
  def handle_event(:info, {:approval, :decided, _}, :tool_wait, _data),
    do: {:keep_state_and_data, [:postpone]}

  def handle_event(:info, {:approval, _, _}, _state, _data), do: :keep_state_and_data

  # Slice 023: the compaction row is written here, in the Session (a row, then a broadcast),
  # from what the Task's model call answered; then the turn goes on, or forks past the hard
  # threshold.
  def handle_event(
        :info,
        {:compaction_done, ref, result},
        :compacting,
        %State{id: id, turn: %{ref: ref}} = data
      ) do
    case result do
      {:ok, attrs} when is_map(attrs) ->
        case Trinity.Sessions.append_message(id, attrs) do
          {:ok, row} ->
            Events.broadcast(id, {:compaction, row})
            continue_after_compaction(data)

          {:error, reason} ->
            fail_turn(data, {:compaction_not_written, reason})
        end

      {:ok, :nothing} ->
        continue_after_compaction(data)

      {:error, {:already_compacted, _}} ->
        continue_after_compaction(data)

      {:error, reason} ->
        fail_turn(data, {:compaction_failed, reason})
    end
  end

  # The Task died: a crash is an error turn, an ordinary exit after its message is nothing.
  def handle_event(
        :info,
        {:DOWN, _mon, :process, pid, reason},
        state,
        %State{turn: %{task: pid}} = data
      )
      when state in [:thinking, :tool_wait, :compacting] and reason != :normal do
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

  # Slice 023: the estimate of the request against the model's window decides between the
  # model call (thinking) and a compaction first (compacting); the fork is decided after the
  # compaction, on what remains.
  defp start_turn(%State{} = data) do
    {session, persona, history, request} = build_request(data)
    window = Tokens.context_tokens(session.model || (persona && persona.model))
    %{soft: soft, hard: hard} = Tokens.thresholds(window)
    estimate = Tokens.estimate(request)

    plan = Compactor.plan(history)

    cond do
      estimate > soft and plan != :nothing ->
        {:compacting, start_compaction(%{data | session: session}, history, session.model)}

      estimate > hard ->
        # Nothing left to compact and still over the window: the fork, with what there is.
        {:forking, %{data | session: session, turn: %{data.turn | held: []}}}

      true ->
        {:thinking, start_model_call(%{data | session: session}, request, history)}
    end
  end

  # The row is read again at every turn (slice 013): a model set between turns through
  # `Trinity.Sessions.set_model/2` is the next turn's model, not the next incarnation's.
  defp build_request(%State{id: id, memory: memory} = data) do
    session = Store.get_session(id) || data.session
    persona = session.persona_id && Store.get_persona(session.persona_id)
    # Slice 020: the declared surface of this turn, into the request and onto the row.
    tools = Trinity.Tools.to_llm_tools()
    history = Trinity.Sessions.history(id, limit: 500)
    # Slice 033: the project's AGENTS.md, read now, so a change is in this turn (live reload).
    context =
      [
        Trinity.Context.AgentsMd.render(session.project_root, session.project_root),
        # Slice 040: the skills index, under its own cap inside the same tier.
        Trinity.Context.SkillsIndex.render(session.project_root)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    # Slice 032: what the semantic tier and past conversations hold about the latest user
    # message, fused and capped; "" when there is no persona or nothing relevant.
    recall = recall_block(session, history)

    {request, truncations} =
      Prompt.build_with_report(session, persona, history, tools,
        memory: memory,
        context: context,
        recall: recall
      )

    Enum.each(truncations, &truncation_receipt(id, &1))
    {session, persona, history, request}
  end

  # Slice 030: a tier cut at its budget is a query receipt naming the tier and the tokens
  # dropped, so the receipt stream shows where the budget binds and no clip is silent.
  defp truncation_receipt(id, %{tier: tier, dropped_tokens: dropped}) do
    Trinity.Receipts.append(Trinity.Receipts.session_scope(id), %{
      kind: "query",
      subject: %{"session_id" => id, "prompt_tier" => Atom.to_string(tier)},
      decision: %{
        "truncated" => true,
        "tier" => Atom.to_string(tier),
        "dropped_tokens" => dropped
      },
      subject_ref: "prompt:#{id}:#{tier}"
    })
  end

  # Slice 032: the retriever runs on the latest user message, over the session's scope chain.
  defp recall_block(%{persona_id: persona_id, id: id}, history) when is_binary(persona_id) do
    case Enum.reverse(history) |> Enum.find(&(&1.role == "user")) do
      nil ->
        ""

      %{content: query} ->
        Trinity.Memory.Retriever.relevant(persona_id, id, query)
        |> Trinity.Memory.Retriever.render()
    end
  end

  defp recall_block(_, _), do: ""

  # Slice 030: the always-on block for this session's chain, frozen in state.
  defp memory_snapshot(%{id: id, persona_id: persona_id}) when is_binary(persona_id),
    do: Trinity.Memory.AlwaysOn.snapshot(persona_id, id)

  defp memory_snapshot(_), do: ""

  defp start_compaction(%State{id: id, task_sup: sup, turn: turn} = data, history, model) do
    ref = make_ref()
    me = self()

    %Task{pid: pid} =
      Task.Supervisor.async_nolink(sup, fn ->
        send(me, {:compaction_done, ref, Compactor.compact(id, history, model: model)})
      end)

    %{data | turn: %{turn | ref: ref, task: pid}}
  end

  defp start_model_call(%State{id: id, task_sup: sup, turn: turn} = data, request, history) do
    # Slice 022: what the model reads is what its answer inherits (docs/07, M1).
    taint = Part.max_taint([turn.taint | Enum.map(history, &Prompt.taint_of/1)])
    turn = %{turn | taint: taint}
    ref = make_ref()
    me = self()

    %Task{pid: pid} =
      Task.Supervisor.async_nolink(sup, fn ->
        result = LLM.stream(request, [session_id: id], &send(me, {:llm_event, ref, &1}))
        send(me, {:llm_done, ref, result})
      end)

    %{
      data
      | turn: %{
          turn
          | ref: ref,
            task: pid,
            buffer: [],
            text: "",
            pending: [],
            finish: nil,
            surface: Trinity.Tools.surface()
        }
    }
  end

  # After a compaction: under the hard threshold, the model call; over it, the fork (AC6).
  defp continue_after_compaction(%State{} = data) do
    {session, persona, history, request} = build_request(data)
    window = Tokens.context_tokens(session.model || (persona && persona.model))
    %{hard: hard} = Tokens.thresholds(window)

    if Tokens.estimate(request) > hard do
      fork(%{data | session: session}, history)
    else
      {:next_state, :thinking, start_model_call(%{data | session: session}, request, history)}
    end
  end

  # A child session (parent_id) starts with the newest compaction and the user's message,
  # and runs the turn; the parent closes its own with a row naming the child and says so.
  defp fork(%State{id: id, session: session} = data, history) do
    compaction = Compactor.latest(history)
    last_user = history |> Enum.filter(&(&1.role == "user")) |> List.last()

    with {:ok, child} <-
           Trinity.Sessions.create_session(%{
             persona_id: session.persona_id,
             parent_id: id,
             origin: session.origin,
             model: session.model,
             title: session.title
           }),
         {:ok, _} <-
           if(compaction,
             do:
               Trinity.Sessions.append_message(child.id, %{
                 role: "system",
                 content: compaction.content,
                 parts: compaction.parts
               }),
             else: {:ok, nil}
           ),
         {:ok, _} <-
           Trinity.Sessions.append_message(id, %{
             role: "assistant",
             content:
               "This conversation continues in a new session (#{child.id}): the context window was full.",
             parts: %{"draft" => false, "forked_to" => child.id, "taint" => "trusted"}
           }) do
      # The child holds the message before anyone hears of the child.
      if last_user, do: Trinity.Sessions.send_user_message(child.id, last_user.content)
      Events.broadcast(id, {:forked, child.id})
      {:next_state, :idle, %{data | turn: nil}}
    else
      {:error, reason} -> fail_turn(data, {:fork_failed, reason})
    end
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
      %{"draft" => false, "tool_calls" => calls, "taint" => Atom.to_string(turn.taint)}
      |> Map.merge(extra)

    meta = %{
      "sentinel" =>
        Enum.map(findings, &%{"kind" => Atom.to_string(&1.kind), "match" => &1.match}),
      "outcome" => Atom.to_string(Sentinel.outcome(findings))
    }

    meta = if turn.finish, do: Map.put(meta, "finish", Atom.to_string(turn.finish)), else: meta
    meta = Map.put(meta, "tool_surface", turn.surface)
    # Whitespace-only text is blank to `validate_required` (fix(s012) at slice 032: a
    # model's lone "\n" before its tool calls lost the assistant row and its calls).
    content = if String.trim(turn.text) == "", do: "(no text)", else: turn.text

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
        observe_turn(data)
        {:next_state, :idle, %{data | turn: nil}}
    end
  end

  # Slice 032: the completed turn (from its user message on) goes to the memory observer,
  # which runs under its own supervisor; the session is idle at once and never waits on it.
  defp observe_turn(%State{id: id, session: session}) do
    row = Store.get_session(id) || session
    history = Trinity.Sessions.history(id, limit: 60)
    last_user = history |> Enum.reverse() |> Enum.find_index(&(&1.role == "user"))
    turn = if last_user, do: Enum.take(history, -(last_user + 1)), else: history

    Trinity.Memory.Observer.observe(
      %{session_id: id, persona_id: row.persona_id, model: row.model},
      Enum.map(turn, &%{id: &1.id, role: &1.role, content: &1.content})
    )
  end

  # After the tool rows: the next model call, or the cap.
  defp next_turn(%State{turn: turn} = data) do
    turn = %{turn | pending: [], held: [], turns: turn.turns + 1}
    data = %{data | turn: turn}

    case Caps.check(turn) do
      :ok ->
        case start_turn(data) do
          {:forking, data} -> fork(data, Trinity.Sessions.history(data.id, limit: 500))
          {state, data} -> {:next_state, state, data}
        end

      {:cap, reason} ->
        cap_reached(data, reason)
    end
  end

  defp start_tools(%State{turn: turn} = data), do: start_tools(data, turn.pending)

  defp start_tools(%State{id: id, session: session, task_sup: sup, turn: turn} = data, calls) do
    ref = make_ref()
    me = self()
    persona = session.persona_id && Store.get_persona(session.persona_id)
    # Slice 033: the project root is the tools' working directory (the row is read again so
    # a root set between turns is this turn's).
    row = Store.get_session(id) || session
    context = %{session_id: id, caller: id, persona: persona, cwd: row.project_root}

    # Slice 020: the turn's calls run at once through the runner in force.
    %Task{pid: pid} =
      Task.Supervisor.async_nolink(sup, fn ->
        results = ToolRunner.run_all(calls, context)
        send(me, {:tools_done, ref, results})
      end)

    %{
      data
      | turn: %{
          turn
          | ref: ref,
            task: pid,
            held: [],
            draft_id: nil,
            buffer: [],
            text: "",
            finish: nil
        }
    }
  end

  # One `tool` row per answer: the text the model reads, and in `parts` the tool's name, whether
  # it succeeded, the result's shape (slice 020: content, truncated, meta) and the definition
  # digest of the tool that answered.
  defp record_tool_results(%State{id: id, turn: turn} = data, results) do
    taints =
      Enum.map(results, fn {call, result} ->
        {content, ok?, parts} =
          case result do
            {:ok, %Trinity.Tools.Result{} = r, meta} ->
              {tool_text(r), true,
               %{
                 "tool_result" => %{
                   "content" => r.content,
                   "truncated" => r.truncated?,
                   "meta" => r.meta,
                   "artifacts" => r.artifacts
                 },
                 "content_parts" => Enum.map(r.parts, &Part.to_map/1),
                 "taint" => Atom.to_string(Part.max_taint(r.parts)),
                 "tool_definition_digest" => meta["tool_definition_digest"]
               }}

            {:error, reason, meta} ->
              {"error: #{error_text(reason)}", false,
               %{
                 "tool_result" => %{"error" => error_text(reason)},
                 "tool_definition_digest" => meta["tool_definition_digest"]
               }}
          end

        {:ok, _} =
          Trinity.Sessions.append_message(id, %{
            role: "tool",
            content: content,
            tool_call_id: call.id,
            parts: Map.merge(%{"tool" => call.name, "ok" => ok?}, parts)
          })

        Prompt.taint_of(%{role: "tool", parts: parts})
      end)

    %{data | turn: %{turn | taint: Part.max_taint([turn.taint | taints])}}
  end

  defp tool_text(%Trinity.Tools.Result{} = r) do
    case Trinity.Tools.Result.as_text(r) do
      "" -> "(empty result)"
      text -> text
    end
  end

  defp error_text({:invalid_args, reasons}) when is_list(reasons),
    do: "invalid arguments: " <> Enum.join(reasons, "; ")

  defp error_text({:crash, {exception, _stack}}) when is_exception(exception),
    do: "the tool crashed: " <> Exception.message(exception)

  defp error_text({:crash, reason}), do: "the tool crashed: " <> inspect(reason)
  defp error_text(:timeout), do: "the tool timed out"
  defp error_text(:unknown_tool), do: "no such tool"
  defp error_text(reason), do: inspect(reason)

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
