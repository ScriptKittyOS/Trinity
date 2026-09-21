# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SessionLive.Show do
  @moduledoc """
  The chat at `/s/:id`. Slice 013.

  On a connected mount the view subscribes to the session's events, starts (or finds) its
  process, loads the history from the database into a stream and the turn in flight from the
  process (`Trinity.Sessions.state/1`: the state name and the draft text). Delta messages that
  were already queued when that reply arrived are dropped, because the reply's text contains
  them: the Session sends both, in order. That is what makes a remount mid-stream show neither
  a gap nor a duplicate (AC5).

  Assigns stay bounded: completed messages live in the `:messages` stream and are rendered
  once; the in-progress text is one assign replaced on every coalesced delta and cleared when
  the final message arrives; the Session already limits deltas to twenty broadcasts a second,
  so the view renders at most that often (AC7).
  """
  use TrinityWeb, :live_view

  import TrinityWeb.ApprovalComponents
  import TrinityWeb.ChatComponents

  alias Trinity.LLM
  alias Trinity.Memory.Tokens
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval
  alias Trinity.Sessions
  alias Trinity.Sessions.Message

  @history_limit 500

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Sessions.get_session(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("No such session."))
         |> push_navigate(to: ~p"/")}

      session ->
        socket =
          socket
          |> assign(
            session: session,
            page_title: session.title || gettext("Chat"),
            status: :idle,
            draft: "",
            tool_calls: [],
            banner: nil,
            last_seq: 0,
            last_user_message: nil,
            models: LLM.models(),
            default_model: LLM.default_model(),
            approvals: [],
            patterns: %{},
            pending_count: 0,
            context_used: 0,
            context_window: Tokens.context_tokens(session.model)
          )
          |> stream_configure(:messages, dom_id: &"message-#{&1.id}")
          |> stream(:messages, [])

        {:ok, if(connected?(socket), do: connect(socket), else: socket)}
    end
  end

  # Subscribe first, then start, then read the turn in flight; last, drop the deltas the
  # state reply already contains.
  defp connect(%{assigns: %{session: session}} = socket) do
    id = session.id
    :ok = Sessions.subscribe(id)
    # Slice 021: this session's requests, and the count of everyone's for the header.
    :ok = Permissions.subscribe(id)
    :ok = Permissions.subscribe(:all)

    {status, text} =
      case Sessions.ensure_started(id) do
        {:ok, _pid} ->
          case Sessions.state(id) do
            %{state: state, text: text} -> {state, text}
            {:error, _} -> {:idle, ""}
          end

        {:error, _} ->
          {:idle, ""}
      end

    drain_deltas(id)
    rows = Sessions.history(id, limit: @history_limit)
    # A row still flagged draft belongs to the turn in flight: its text is what state/1 gave,
    # and its final form arrives as an event under the same id. Nothing else carries the flag:
    # the rehydrate marks a leftover draft interrupted before ensure_started/1 returns.
    done = Enum.reject(rows, &(&1.parts["draft"] == true))
    last_seq = rows |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    socket
    |> assign(status: status, draft: text, last_seq: last_seq)
    |> assign(
      approvals: Permissions.pending(id),
      pending_count: length(Permissions.pending(:all))
    )
    |> assign_context(rows)
    |> assign(
      last_user_message: done |> Enum.filter(&(&1.role == "user")) |> List.last() |> content()
    )
    |> stream(:messages, done)
  end

  # Slice 023: the estimate of the next request, from the rows the page holds.
  defp assign_context(socket, rows) do
    session = socket.assigns.session
    request = Trinity.Sessions.Prompt.build(session, nil, rows, Trinity.Tools.to_llm_tools())

    assign(socket,
      context_used: Tokens.estimate(request),
      context_window: Tokens.context_tokens(session.model)
    )
  end

  defp refresh_context(socket) do
    assign_context(socket, Sessions.history(socket.assigns.session.id, limit: 500))
  end

  defp drain_deltas(id) do
    receive do
      {:session, ^id, {:assistant_delta, _}} -> drain_deltas(id)
    after
      0 -> :ok
    end
  end

  defp content(nil), do: nil
  defp content(%Message{content: content}), do: content

  ## Events from the page

  @impl true
  def handle_event("send", %{"content" => content}, socket) do
    content = String.trim(content)

    if content == "" do
      {:noreply, socket}
    else
      send_message(socket, content)
    end
  end

  def handle_event("cancel", _params, socket) do
    _ = Sessions.cancel_turn(socket.assigns.session.id)
    {:noreply, socket}
  end

  def handle_event("retry", _params, %{assigns: %{last_user_message: nil}} = socket),
    do: {:noreply, assign(socket, banner: nil)}

  def handle_event("retry", _params, %{assigns: %{last_user_message: content}} = socket),
    do: send_message(socket, content)

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, banner: nil)}

  # Slice 033: the project root, saved on submit; empty clears it. The next turn's tools
  # work there and its AGENTS.md is read.
  def handle_event("set_project_root", %{"project_root" => root}, socket) do
    value = if String.trim(root) == "", do: nil, else: String.trim(root)

    case Sessions.set_project_root(socket.assigns.session.id, value) do
      {:ok, session} ->
        {:noreply, socket |> assign(session: session) |> refresh_context()}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Project root not set: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("set_model", %{"model" => model}, socket) do
    case Sessions.set_model(socket.assigns.session.id, model) do
      {:ok, session} ->
        {:noreply, socket |> assign(session: session) |> refresh_context()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Model not set: %{reason}", reason: inspect(reason)))}
    end
  end

  def handle_event("new_session", _params, socket),
    do: {:noreply, TrinityWeb.SessionLive.Index.new_session(socket)}

  # Slice 021: a button is a request for a decision; the record is the gate's.
  def handle_event("approval_decide", %{"id" => id, "decision" => decision}, socket)
      when decision in ["once", "session", "always", "deny"] do
    opts =
      if decision == "always",
        do: [pattern: Map.get(socket.assigns.patterns, id) || suggested(socket, id)],
        else: []

    case Permissions.decide_request(id, String.to_existing_atom(decision), opts) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Not decided: %{reason}", reason: inspect(reason)))}
    end
  end

  def handle_event("approval_pattern", %{"approval_id" => id, "pattern" => pattern}, socket),
    do: {:noreply, assign(socket, patterns: Map.put(socket.assigns.patterns, id, pattern))}

  defp suggested(socket, id) do
    case Enum.find(socket.assigns.approvals, &(&1.id == id)) do
      nil -> "*"
      approval -> suggest_pattern(approval)
    end
  end

  defp send_message(socket, content) do
    id = socket.assigns.session.id

    case Sessions.send_user_message(id, content) do
      {:ok, _message} ->
        socket = if socket.assigns.session.title, do: socket, else: title(socket, content)

        {:noreply,
         socket
         |> assign(banner: nil, last_user_message: content)
         |> push_event("composer:clear", %{})}

      {:error, {:busy, state}} ->
        {:noreply,
         put_flash(socket, :error, gettext("Trinity is busy (%{state}).", state: state))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Not sent: %{reason}", reason: inspect(reason)))}
    end
  end

  defp title(socket, content) do
    case Sessions.set_title(socket.assigns.session.id, String.slice(content, 0, 60)) do
      {:ok, session} -> assign(socket, session: session, page_title: session.title)
      {:error, _} -> socket
    end
  end

  ## Events from the Session

  @impl true
  def handle_info({:session, id, event}, %{assigns: %{session: %{id: id}}} = socket) do
    {:noreply, apply_event(event, socket)}
  end

  def handle_info({:approval, kind, %Approval{} = approval}, socket) do
    socket =
      if approval.session_id == socket.assigns.session.id,
        do: apply_approval(kind, approval, socket),
        else: socket

    {:noreply, assign(socket, pending_count: length(Permissions.pending(:all)))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The page hears each request twice (the session's topic and everyone's); one card.
  defp apply_approval(:requested, approval, socket) do
    if Enum.any?(socket.assigns.approvals, &(&1.id == approval.id)),
      do: socket,
      else: assign(socket, approvals: socket.assigns.approvals ++ [approval])
  end

  defp apply_approval(:decided, approval, socket) do
    assign(socket,
      approvals: Enum.reject(socket.assigns.approvals, &(&1.id == approval.id)),
      patterns: Map.delete(socket.assigns.patterns, approval.id)
    )
  end

  defp apply_event({:user_message, %Message{} = m}, socket) do
    socket
    |> insert(m)
    |> assign(last_user_message: m.content, banner: nil)
  end

  defp apply_event({:assistant_delta, text}, %{assigns: %{draft: draft}} = socket) do
    assign(socket, draft: draft <> text)
  end

  # The final row replaces the draft. Tool rows are written without an event of their own,
  # so anything the database has past the last seen seq comes along here.
  defp apply_event({:assistant_message, %Message{} = m}, socket) do
    socket
    |> catch_up()
    |> insert(m)
    |> assign(draft: "", tool_calls: [])
    |> refresh_context()
  end

  # Slice 023: a compaction row is a card in the stream, and the conversation may move on.
  defp apply_event({:compaction, %Message{} = m}, socket) do
    socket |> insert(m) |> refresh_context()
  end

  defp apply_event({:forked, child_id}, socket) do
    socket
    |> put_flash(:info, gettext("The context window was full; the conversation continues here."))
    |> push_navigate(to: ~p"/s/#{child_id}")
  end

  defp apply_event({:turn_interrupted, %Message{} = m}, socket) do
    socket
    |> catch_up()
    |> insert(m)
    |> assign(draft: "", tool_calls: [], banner: :interrupted)
  end

  defp apply_event(
         {:tool_call, %{id: _, name: _} = call},
         %{assigns: %{tool_calls: calls}} = socket
       ),
       do: assign(socket, tool_calls: calls ++ [call])

  defp apply_event({:state, state}, socket) do
    socket = assign(socket, status: state)
    if state == :idle, do: assign(socket, draft: "", tool_calls: []), else: socket
  end

  defp apply_event({:error, reason}, socket), do: assign(socket, banner: {:error, reason})
  defp apply_event(_other, socket), do: socket

  defp insert(socket, %Message{} = m) do
    socket
    |> stream_insert(:messages, m)
    |> assign(last_seq: max(socket.assigns.last_seq, m.seq))
  end

  defp catch_up(%{assigns: %{session: session, last_seq: last_seq}} = socket) do
    session.id
    |> Sessions.history(offset: last_seq, limit: @history_limit)
    |> Enum.reject(&(&1.parts["draft"] == true))
    |> Enum.reduce(socket, &insert(&2, &1))
  end

  ## The page

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="min-w-0 truncate">{@session.title || gettext("Untitled session")}</span>
        <.status_pill status={@status} />
        <.model_picker models={@models} value={@session.model} default={@default_model} />
        <form id="project-root" phx-submit="set_project_root" class="contents">
          <input
            name="project_root"
            value={@session.project_root}
            placeholder={gettext("project root")}
            title={gettext("The directory the tools work in and AGENTS.md is read from; Enter saves")}
            class="w-44 rounded-field border border-base-300 bg-base-100 px-2 py-1 font-mono text-meta"
          />
        </form>
        <.context_indicator used={@context_used} window={@context_window} />
        <.pending_indicator count={@pending_count} />
        <.link
          id="receipts-link"
          navigate={~p"/s/#{@session.id}/receipts"}
          class="text-meta opacity-70 hover:opacity-100"
          title={gettext("This session's receipts")}
        >
          {gettext("receipts")}
        </.link>
        <.link id="search-link" navigate={~p"/search"} class="text-meta opacity-70 hover:opacity-100">
          {gettext("search")}
        </.link>
      </:bar>
      <div id="chat" phx-hook="Shortcuts" class="mx-auto flex h-full max-w-4xl flex-col">
        <div
          id="scroll"
          phx-hook="ScrollToBottom"
          class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-4 py-4"
        >
          <div id="messages" phx-update="stream" class="flex flex-col gap-3">
            <.message :for={{dom_id, message} <- @streams.messages} id={dom_id} message={message} />
          </div>
          <.draft
            :if={@status != :idle or @draft != ""}
            text={@draft}
            status={@status}
            tool_calls={@tool_calls}
          />
        </div>
        <div class="flex flex-col gap-2 border-t border-base-300 bg-base-100/60 px-4 py-3">
          <.approval_card :for={a <- @approvals} approval={a} pattern={Map.get(@patterns, a.id)} />
          <.banner kind={@banner} />
          <.composer status={@status} disabled={@status != :idle} />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
