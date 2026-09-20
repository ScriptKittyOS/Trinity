# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ChatComponents do
  @moduledoc """
  The chat's component vocabulary, decided at slice 013 and reused by every later surface:
  `message` (a bubble with role, time and usage), `tool_card` (name, arguments, status, an
  expandable result), `draft` (the in-progress assistant message), `composer`, `model_picker`,
  `status_pill` and `banner`. Tokens come from `assets/css/app.css`; nothing here names a colour
  outside the theme.
  """
  use Phoenix.Component
  use Gettext, backend: TrinityWeb.Gettext

  import TrinityWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias Trinity.Sessions.Message
  alias TrinityWeb.Markdown

  @doc "One persisted message. A `tool` row renders as a tool card; the others as bubbles."
  attr :message, Message, required: true
  attr :id, :string, required: true

  def message(%{message: %Message{role: "tool"}} = assigns) do
    ~H"""
    <div id={@id} class="flex justify-start">
      <.tool_card
        name={@message.parts["tool"] || "tool"}
        status={if @message.parts["ok"], do: :ok, else: :error}
        result={@message.content}
      />
    </div>
    """
  end

  def message(assigns) do
    ~H"""
    <div id={@id} class={["flex", (@message.role == "user" && "justify-end") || "justify-start"]}>
      <div class={[
        "max-w-[min(48rem,90%)] rounded-panel px-4 py-3 text-ui",
        @message.role == "user" && "bg-primary/15 border border-primary/20",
        @message.role == "assistant" && "bg-base-100 border border-base-300",
        @message.role == "system" && "bg-base-300/60 border border-base-300 italic"
      ]}>
        <div class="mb-1 flex flex-wrap items-center gap-2 text-meta opacity-70">
          <span class="font-semibold uppercase tracking-wide">{role_label(@message.role)}</span>
          <.local_time id={@id <> "-time"} at={@message.inserted_at} />
          <.usage_badge usage={@message.usage} />
          <.outcome_label parts={@message.parts} />
        </div>
        <div :if={@message.role == "assistant"} class="md">
          {Markdown.to_html(@message.content)}
        </div>
        <div :if={@message.role != "assistant"} class="whitespace-pre-wrap break-words" phx-no-format>{@message.content}</div>
        <div :if={calls = tool_calls(@message)} class="mt-2 flex flex-col gap-2">
          <.tool_card
            :for={call <- calls}
            name={call["name"]}
            args={call["args"]}
            status={:requested}
          />
        </div>
      </div>
    </div>
    """
  end

  @doc "A tool call: its name, an argument summary, a status, and the result behind a disclosure."
  attr :name, :string, required: true
  attr :args, :map, default: nil
  attr :status, :atom, values: [:requested, :running, :ok, :error], required: true
  attr :result, :string, default: nil

  def tool_card(assigns) do
    ~H"""
    <details class="group w-full max-w-[min(48rem,90%)] rounded-field border border-base-300 bg-base-200 text-ui open:bg-base-100">
      <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2">
        <.icon name="hero-wrench-screwdriver-micro" class="size-4 opacity-70" />
        <span class="font-mono text-sm">{@name}</span>
        <span :if={@args} class="truncate font-mono text-meta opacity-60">{args_summary(@args)}</span>
        <span class="ml-auto flex items-center gap-1 text-meta">
          <span class={[
            "size-2 rounded-pill",
            @status == :requested && "bg-info",
            @status == :running && "bg-warning animate-pulse",
            @status == :ok && "bg-success",
            @status == :error && "bg-error"
          ]} />
          {status_label(@status)}
        </span>
        <.icon
          name="hero-chevron-down-micro"
          class="size-4 opacity-50 transition group-open:rotate-180"
        />
      </summary>
      <div :if={@args && @args != %{}} class="border-t border-base-300 px-3 py-2">
        <pre class="whitespace-pre-wrap break-words font-mono text-sm">{Jason.encode!(@args, pretty: true)}</pre>
      </div>
      <div :if={@result} class="border-t border-base-300 px-3 py-2">
        <pre class="whitespace-pre-wrap break-words font-mono text-sm">{@result}</pre>
      </div>
    </details>
    """
  end

  @doc """
  The assistant message in progress: the text so far rendered with fragment completion, the tool
  calls this turn has started, and a pulse while nothing has arrived yet.
  """
  attr :text, :string, required: true
  attr :status, :atom, required: true
  attr :tool_calls, :list, default: []

  def draft(assigns) do
    ~H"""
    <div id="draft" class="flex justify-start" data-status={@status}>
      <div class="max-w-[min(48rem,90%)] rounded-panel border border-base-300 bg-base-100 px-4 py-3 text-ui">
        <div class="mb-1 flex items-center gap-2 text-meta opacity-70">
          <span class="font-semibold uppercase tracking-wide">{role_label("assistant")}</span>
          <.status_pill id="draft-status" status={@status} />
        </div>
        <div :if={@text != ""} class="md md-streaming">
          {Markdown.to_html(@text, streaming: true)}
        </div>
        <div
          :if={@text == "" and @tool_calls == []}
          class="flex gap-1 py-1"
          aria-label={gettext("thinking")}
        >
          <span class="size-2 animate-bounce rounded-pill bg-primary [animation-delay:0ms]" />
          <span class="size-2 animate-bounce rounded-pill bg-primary [animation-delay:150ms]" />
          <span class="size-2 animate-bounce rounded-pill bg-primary [animation-delay:300ms]" />
        </div>
        <div :if={@tool_calls != []} class="mt-2 flex flex-col gap-2">
          <.tool_card :for={call <- @tool_calls} name={call.name} status={:running} />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The composer: Enter sends, Shift+Enter breaks the line (the `Composer` hook), disabled unless
  the session is idle. The Cancel button appears while a turn is in flight.
  """
  attr :status, :atom, required: true
  attr :disabled, :boolean, required: true

  def composer(assigns) do
    ~H"""
    <form id="composer" phx-submit="send" class="flex items-end gap-2">
      <textarea
        id="composer-input"
        name="content"
        rows="1"
        phx-hook="Composer"
        placeholder={
          if @disabled,
            do: gettext("Trinity is working, Esc cancels"),
            else: gettext("Message Trinity")
        }
        disabled={@disabled}
        autocomplete="off"
        class="max-h-48 min-h-11 flex-1 resize-none rounded-field border border-base-300 bg-base-100 px-3 py-2.5 text-ui outline-none focus:border-primary disabled:opacity-60"
      ></textarea>
      <button
        :if={not @disabled}
        type="submit"
        class="grid size-11 shrink-0 cursor-pointer place-items-center rounded-field bg-primary text-primary-content transition hover:brightness-110"
        aria-label={gettext("Send")}
      >
        <.icon name="hero-paper-airplane-micro" class="size-5" />
      </button>
      <button
        :if={@disabled}
        type="button"
        id="cancel"
        phx-click="cancel"
        class="flex h-11 shrink-0 cursor-pointer items-center gap-1 rounded-field border border-error/50 px-3 text-ui text-error transition hover:bg-error/10"
      >
        <.icon name="hero-stop-micro" class="size-4" /> {gettext("Cancel")}
      </button>
    </form>
    """
  end

  @doc "The model picker: the registry's ids, the session's current one selected."
  attr :models, :list, required: true, doc: "registry entries"
  attr :value, :string, default: nil, doc: "the session's model id, or nil for the default"
  attr :default, :string, default: nil, doc: "the registry default id"

  def model_picker(assigns) do
    ~H"""
    <form id="model-picker" phx-change="set_model" class="contents">
      <label class="flex items-center gap-1 text-meta opacity-80">
        <.icon name="hero-cpu-chip-micro" class="size-4" />
        <select
          name="model"
          class="cursor-pointer rounded-field border border-base-300 bg-base-100 px-2 py-1 text-meta"
          aria-label={gettext("Model")}
        >
          <option :for={m <- @models} value={m.id} selected={m.id == (@value || @default)}>
            {m.id}
          </option>
        </select>
      </label>
    </form>
    """
  end

  @doc "The session's state as a small pill."
  attr :id, :string, default: "status"
  attr :status, :atom, required: true

  def status_pill(assigns) do
    ~H"""
    <span
      id={@id}
      data-status={@status}
      class={[
        "inline-flex items-center gap-1 rounded-pill px-2 py-0.5 text-meta",
        @status == :idle && "bg-base-300",
        @status in [:thinking, :compacting] && "bg-primary/20 text-primary",
        @status in [:tool_wait, :approval_wait] && "bg-warning/20 text-warning",
        @status == :error && "bg-error/20 text-error"
      ]}
    >
      <span class={["size-1.5 rounded-pill bg-current", @status != :idle && "animate-pulse"]} />
      {status_text(@status)}
    </span>
    """
  end

  @doc "The banner over the composer: an interrupted turn with Retry, or an error."
  attr :kind, :any, required: true, doc: ":interrupted | {:error, reason} | nil"

  def banner(assigns) do
    ~H"""
    <div
      :if={@kind}
      id="banner"
      role="status"
      class={[
        "flex items-center gap-3 rounded-field border px-3 py-2 text-ui",
        @kind == :interrupted && "border-warning/50 bg-warning/10",
        match?({:error, _}, @kind) && "border-error/50 bg-error/10"
      ]}
    >
      <.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0" />
      <span :if={@kind == :interrupted}>
        {gettext("The last turn was interrupted; what arrived is kept.")}
      </span>
      <span :if={match?({:error, _}, @kind)}>
        {gettext("The turn failed: %{reason}", reason: error_text(@kind))}
      </span>
      <button
        :if={@kind == :interrupted}
        type="button"
        phx-click="retry"
        class="ml-auto cursor-pointer rounded-pill border border-current px-3 py-0.5 text-meta font-semibold hover:bg-base-100"
      >
        {gettext("Retry")}
      </button>
      <button
        type="button"
        phx-click={JS.push("dismiss")}
        class="cursor-pointer opacity-60 hover:opacity-100"
        aria-label={gettext("Dismiss")}
      >
        <.icon name="hero-x-mark-micro" class="size-4" />
      </button>
    </div>
    """
  end

  attr :usage, :map, default: nil

  defp usage_badge(assigns) do
    ~H"""
    <span
      :if={@usage && @usage != %{}}
      class="rounded-pill bg-base-300 px-1.5 font-mono"
      title={gettext("tokens in / out")}
    >
      {@usage["input_tokens"] || 0}/{@usage["output_tokens"] || 0}
    </span>
    """
  end

  attr :parts, :map, required: true

  defp outcome_label(assigns) do
    ~H"""
    <span :if={@parts["interrupted"]} class="rounded-pill bg-warning/20 px-1.5 text-warning">
      {gettext("interrupted")}
    </span>
    <span :if={@parts["error"]} class="rounded-pill bg-error/20 px-1.5 text-error">
      {gettext("error")}
    </span>
    <span :if={@parts["cap"]} class="rounded-pill bg-warning/20 px-1.5 text-warning">
      {gettext("cap: %{cap}", cap: @parts["cap"])}
    </span>
    """
  end

  defp tool_calls(%Message{parts: parts}) do
    case parts["tool_calls"] do
      [_ | _] = calls -> calls
      _ -> nil
    end
  end

  defp role_label("user"), do: gettext("you")
  defp role_label("assistant"), do: gettext("trinity")
  defp role_label(other), do: other

  defp status_label(:requested), do: gettext("requested")
  defp status_label(:running), do: gettext("running")
  defp status_label(:ok), do: gettext("ok")
  defp status_label(:error), do: gettext("error")

  defp status_text(:idle), do: gettext("idle")
  defp status_text(:thinking), do: gettext("thinking")
  defp status_text(:tool_wait), do: gettext("running tools")
  defp status_text(:approval_wait), do: gettext("waiting for approval")
  defp status_text(:compacting), do: gettext("compacting")
  defp status_text(:error), do: gettext("error")
  defp status_text(other), do: to_string(other)

  defp error_text({:error, reason}) when is_binary(reason), do: reason
  defp error_text({:error, %{message: message}}) when is_binary(message), do: message
  defp error_text({:error, reason}), do: inspect(reason)

  defp args_summary(args) when is_map(args) do
    args
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> String.slice(0, 80)
  end

  @doc "A time, rendered as UTC and rewritten in the viewer's zone by the LocalTime hook once mounted."
  attr :id, :string, required: true
  attr :at, :any, required: true, doc: "a DateTime, or nil for nothing"
  attr :format, :string, values: ~w(time datetime), default: "time"

  def local_time(assigns) do
    ~H"""
    <time
      :if={@at}
      id={@id}
      phx-hook="LocalTime"
      datetime={DateTime.to_iso8601(@at)}
      data-format={@format}
    >
      {Calendar.strftime(@at, if(@format == "time", do: "%H:%M", else: "%Y-%m-%d %H:%M"))} UTC
    </time>
    """
  end
end
