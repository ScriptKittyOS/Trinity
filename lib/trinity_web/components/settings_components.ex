# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SettingsComponents do
  @moduledoc """
  The pieces `/settings` and `/setup` share (slice 100): a provider key's row, the folders the
  filesystem tools may use, and the data directory; with the event handling behind them, so the
  two pages cannot disagree about where a key goes or what a folder must be.

  **A key goes to the keychain and nowhere else** (`Trinity.Secrets.store/2`). The field is a
  password input whose value is never rendered back; its parameter is `secret`, which
  `config :phoenix, :filter_parameters` logs as `[FILTERED]`. With no keychain the field is
  disabled and the page says how to supply the key instead (the environment).
  """
  use Phoenix.Component
  use Gettext, backend: TrinityWeb.Gettext

  require Phoenix.LiveView

  alias Trinity.{Desktop, Secrets, Settings}

  ## State

  @doc "The key names the pages offer: each model's `api_key_env`, then the web search key."
  @spec key_names() :: [String.t()]
  def key_names do
    from_models =
      Trinity.LLM.models() |> Enum.map(&Map.get(&1, :api_key_env)) |> Enum.reject(&is_nil/1)

    Enum.uniq(from_models ++ ["BRAVE_SEARCH_API_KEY"])
  end

  @doc "Assigns `keychain?` and `keys` (each name with where it is found, never its value)."
  @spec assign_keys(Phoenix.LiveView.Socket.t(), [String.t()]) :: Phoenix.LiveView.Socket.t()
  def assign_keys(socket, names \\ key_names()) do
    assign(socket,
      keychain?: Secrets.keychain_available?(),
      keys: Enum.map(names, &%{name: &1, source: Secrets.source(&1)})
    )
  end

  @doc "Assigns the saved folders."
  @spec assign_roots(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_roots(socket), do: assign(socket, roots: Settings.get(:fs_roots), root_error: nil)

  ## Events

  @doc "Stores a key typed into the page. The value is not kept in the socket or logged."
  @spec save_key(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def save_key(socket, name, value) do
    socket =
      case Secrets.store(name, value) do
        :ok ->
          Phoenix.LiveView.put_flash(
            socket,
            :info,
            gettext("Saved %{name} to the keychain.", name: name)
          )

        {:error, :keychain_unavailable} ->
          Phoenix.LiveView.put_flash(socket, :error, gettext("No keychain in this run."))

        {:error, :invalid_value} ->
          Phoenix.LiveView.put_flash(
            socket,
            :error,
            gettext("That key is empty or has a line break in it.")
          )

        {:error, reason} ->
          Phoenix.LiveView.put_flash(
            socket,
            :error,
            gettext("The keychain refused: %{reason}", reason: inspect(reason))
          )
      end

    assign_keys(socket)
  end

  @doc "Removes a key from the keychain."
  @spec remove_key(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def remove_key(socket, name) do
    _ = Secrets.delete(name)
    assign_keys(socket)
  end

  @doc "Adds a folder after checking it is an existing absolute directory."
  @spec add_root(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def add_root(socket, root) do
    root = String.trim(root)

    cond do
      Path.type(root) != :absolute ->
        assign(socket, root_error: gettext("A folder must be an absolute path."))

      not File.dir?(root) ->
        assign(socket, root_error: gettext("No folder exists at %{root}.", root: root))

      true ->
        roots = Enum.uniq(Settings.get(:fs_roots) ++ [root])

        case Settings.put(:fs_roots, roots) do
          :ok -> assign_roots(socket)
          {:error, reason} -> assign(socket, root_error: inspect(reason))
        end
    end
  end

  @doc "Removes a folder."
  @spec remove_root(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def remove_root(socket, root) do
    :ok = Settings.put(:fs_roots, List.delete(Settings.get(:fs_roots), root))
    assign_roots(socket)
  end

  @doc "Opens the native folder dialog without blocking the page; `picked/2` handles the answer."
  @spec pick_root(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def pick_root(socket) do
    Phoenix.LiveView.start_async(socket, :pick_root, fn ->
      Desktop.open_dialog(kind: :folder, title: "Choose a folder Trinity may use")
    end)
  end

  @doc "The dialog's answer: each folder chosen is added the way a typed one is."
  @spec picked(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def picked(socket, {:ok, {:ok, paths}}), do: Enum.reduce(paths, socket, &add_root(&2, &1))

  def picked(socket, {:ok, {:error, :no_shell}}),
    do:
      assign(socket, root_error: gettext("No desktop shell in this run; type the folder below."))

  def picked(socket, other),
    do: assign(socket, root_error: gettext("The dialog did not answer: %{r}", r: inspect(other)))

  ## Components

  @doc "One provider key: where it is found, and a field that stores it in the keychain."
  attr :key, :map, required: true
  attr :keychain?, :boolean, required: true

  def key_row(assigns) do
    ~H"""
    <form
      id={"key-#{@key.name}"}
      phx-submit="save_key"
      class="flex flex-wrap items-center gap-2"
      autocomplete="off"
    >
      <input type="hidden" name="name" value={@key.name} />
      <code class="w-56 shrink-0 text-meta">{@key.name}</code>
      <span data-source={@key.source} class="w-28 shrink-0 text-meta opacity-80">
        {source_label(@key.source)}
      </span>
      <input
        type="password"
        name="secret[value]"
        value=""
        autocomplete="off"
        disabled={!@keychain?}
        placeholder={if @keychain?, do: gettext("paste a key"), else: gettext("no keychain")}
        class="input input-sm w-64"
      />
      <button :if={@keychain?} type="submit" class="btn btn-sm">{gettext("Save to keychain")}</button>
      <button
        :if={@key.source == :keychain}
        type="button"
        phx-click="remove_key"
        phx-value-name={@key.name}
        class="btn btn-sm btn-ghost"
      >
        {gettext("Remove")}
      </button>
    </form>
    """
  end

  defp source_label(:keychain), do: gettext("in the keychain")
  defp source_label(:env), do: gettext("from the environment")
  defp source_label(:none), do: gettext("not set")

  @doc "The folders the filesystem tools may use, with the dialog and a typed fallback."
  attr :roots, :list, required: true
  attr :root_error, :string, default: nil

  def roots(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <ul id="roots" class="flex flex-col gap-1 font-mono text-meta">
        <li :for={root <- @roots} data-root={root} class="flex items-center gap-2">
          <span class="break-all">{root}</span>
          <button
            type="button"
            phx-click="remove_root"
            phx-value-root={root}
            class="btn btn-xs btn-ghost"
          >
            {gettext("Remove")}
          </button>
        </li>
        <li :if={@roots == []} class="opacity-60">{gettext("No folders yet.")}</li>
      </ul>
      <div class="flex flex-wrap items-center gap-2">
        <button id="pick-root" type="button" phx-click="pick_root" class="btn btn-sm">
          {gettext("Choose a folder...")}
        </button>
        <form id="root-form" phx-submit="add_root" class="flex items-center gap-2">
          <input
            type="text"
            name="root"
            value=""
            placeholder={gettext("or type an absolute path")}
            class="input input-sm w-72 font-mono"
          />
          <button type="submit" class="btn btn-sm btn-ghost">{gettext("Add")}</button>
        </form>
      </div>
      <p :if={@root_error} class="text-meta text-error">{@root_error}</p>
    </div>
    """
  end
end
