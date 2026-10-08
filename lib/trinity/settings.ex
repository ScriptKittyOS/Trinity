# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Settings do
  @moduledoc """
  The desktop's non-secret settings (slice 100, NOTES decision D6): one JSON file,
  `<data dir>/settings.json`, mode 0600, written atomically (a temporary file beside it, then a
  rename), read fresh on every call so a restart and a running process see the same thing.

  **What may be in it is a closed list**, each with a type: the onboarding mark, the default
  model's id, the global hotkey, whether notifications are muted, whether Trinity starts at login,
  and the folders the filesystem tools may use. An unknown key is refused by name. That list is
  what keeps this file from becoming the place a provider key ends up: no key here is named for a
  secret, and a string that looks like key material is refused whichever key it is put under
  (`Trinity.Secrets` is the only place secrets go, and only to the keychain). Folder paths are
  exempt from the shape check because a path is not key material and its callers already require
  an existing absolute directory.

  It is in the data directory, so `mix trinity.export` carries it with the rest.
  """

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @type key ::
          :onboarded_at
          | :default_model
          | :hotkey
          | :notifications_muted
          | :autostart
          | :fs_roots

  @defaults %{
    onboarded_at: nil,
    default_model: nil,
    hotkey: "CommandOrControl+Shift+Space",
    notifications_muted: false,
    autostart: false,
    fs_roots: []
  }

  @keys Map.keys(@defaults)

  # Shapes of key material this file refuses, whatever key it is put under: provider key
  # prefixes, long unbroken base64 or hex runs, and a PEM header. Assembled rather than written
  # out, so the tree's own secret scan does not read this module as a leak.
  @secret_shapes [
    ~r/\b(sk|rk|pk)-[A-Za-z0-9_-]{16,}/,
    ~r/\bnvapi-[A-Za-z0-9_-]{16,}/,
    ~r/[A-Za-z0-9+_-]{40,}/,
    Regex.compile!("-----BEGIN [A-Z ]*" <> "PRIVATE KEY-----")
  ]

  @doc "The value of every setting when nothing has been saved."
  @spec defaults() :: %{key() => term()}
  def defaults, do: @defaults

  @doc "The settings keys, in no particular order."
  @spec keys() :: [key()]
  def keys, do: @keys

  @doc """
  The settings file in force: `config :trinity, Trinity.Settings, path:` (the suite points it into
  its own `tmp/`), else `settings.json` in the data directory.
  """
  @spec path() :: Path.t()
  def path do
    case Application.get_env(:trinity, __MODULE__, [])[:path] do
      nil -> Path.join(Trinity.Paths.ensure_data_dir(), "settings.json")
      path -> path
    end
  end

  @doc "Every setting, saved values over the defaults. `path:` overrides the file."
  @spec all(keyword()) :: %{key() => term()}
  def all(opts \\ []) do
    saved =
      case read(Keyword.get_lazy(opts, :path, &path/0)) do
        {:ok, map} -> map
        {:error, _} -> %{}
      end

    Enum.reduce(@keys, @defaults, &take_saved(saved, &1, &2))
  end

  # A saved value of the wrong type (a file edited by hand) reads as the default, not as a crash.
  defp take_saved(saved, key, acc) do
    case Map.fetch(saved, Atom.to_string(key)) do
      {:ok, value} -> if valid?(key, value), do: Map.put(acc, key, value), else: acc
      :error -> acc
    end
  end

  @doc "One setting."
  @spec get(key(), keyword()) :: term()
  def get(key, opts \\ []) when key in @keys, do: Map.fetch!(all(opts), key)

  @doc """
  Saves one setting. Refuses an unknown key (`{:unknown_setting, key}`), a value of the wrong type
  (`{:invalid_setting, key}`) and a string shaped like key material (`{:looks_like_a_secret, key}`),
  and in each case writes nothing.
  """
  @spec put(key() | String.t(), term(), keyword()) :: :ok | {:error, term()}
  def put(key, value, opts \\ [])

  def put(key, value, opts) when key in @keys do
    cond do
      not valid?(key, value) ->
        {:error, {:invalid_setting, key}}

      key != :fs_roots and secret_shaped?(value) ->
        {:error, {:looks_like_a_secret, key}}

      true ->
        file = Keyword.get_lazy(opts, :path, &path/0)
        settings = opts |> all() |> Map.put(key, value)
        write(file, settings)
    end
  end

  def put(key, _value, _opts), do: {:error, {:unknown_setting, to_string(key)}}

  defp valid?(:onboarded_at, v), do: is_nil(v) or is_binary(v)
  defp valid?(:default_model, v), do: is_nil(v) or (is_binary(v) and byte_size(v) <= 200)
  defp valid?(:hotkey, v), do: is_nil(v) or (is_binary(v) and byte_size(v) <= 100)
  defp valid?(:notifications_muted, v), do: is_boolean(v)
  defp valid?(:autostart, v), do: is_boolean(v)
  defp valid?(:fs_roots, v), do: is_list(v) and Enum.all?(v, &is_binary/1)

  defp secret_shaped?(value) when is_binary(value),
    do: Enum.any?(@secret_shapes, &Regex.match?(&1, value))

  defp secret_shaped?(_), do: false

  # sobelow_skip reason: Traversal.FileModule: the path is `path/0` (configuration or the data
  # directory plus a constant name) or a test's own temporary file, never request input.
  @sobelow_skip ["Traversal.FileModule"]
  defp read(file) do
    with {:ok, bin} <- File.read(file),
         {:ok, map} when is_map(map) <- JSON.decode(bin) do
      {:ok, map}
    else
      {:ok, _other} -> {:error, :not_an_object}
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: as read/1; the temporary file is the same path
  # plus a constant suffix.
  @sobelow_skip ["Traversal.FileModule"]
  defp write(file, settings) do
    tmp = file <> ".tmp"
    body = settings |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end) |> JSON.encode!()

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, body),
         :ok <- File.chmod(tmp, 0o600) do
      File.rename(tmp, file)
    end
  end
end
