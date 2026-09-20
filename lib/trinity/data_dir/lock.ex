# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.DataDir.Lock do
  @moduledoc """
  One node per data directory, enforced rather than assumed. Slice 010.

  The single-connection pool makes concurrent writes safe within one BEAM node and does
  nothing about two OS processes opening the same SQLite file, which is the corruption the
  vision names. Slice 061 ships a headless profile and slice 100 a desktop app, and nothing
  else stops them sharing a data directory. This process takes `<data_dir>/LOCK` at boot,
  before the Repo starts, and refuses to start when the file is held by a live process,
  naming the holder's OS pid and mode. The application then fails to start with that reason,
  and no database file has been opened.

  The file is created with `:exclusive`, so two boots racing for it cannot both win. It
  carries the holder's OS pid, mode (`desktop` or `headless`), a per-boot token and the time.
  A file whose pid is no longer alive is stale and is taken over; on platforms where
  liveness cannot be read this module treats the file as held, so the only way past a
  dead holder there is removing the file by hand, which is the safe direction.

  The lock file is not the database and is never inside a transaction; it says nothing
  about the integrity of the data, only about who may open it.
  """

  use GenServer

  @type mode :: :desktop | :headless
  @type holder :: %{pid: pos_integer(), mode: mode(), token: String.t(), at: String.t()}

  @file_name "LOCK"

  ## Client

  @doc "Starts the lock as a supervised child. `dir:` and `mode:` are required."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Takes the lock file in `dir` for `mode`. Returns `{:ok, holder}` with what was written, or
  `{:error, {:held, holder}}` naming the live holder, or `{:error, {:unwritable, reason}}`.
  Pure with respect to processes: no GenServer involved, so a test can call it directly.
  """
  @spec acquire(Path.t(), mode()) ::
          {:ok, holder()} | {:error, {:held, holder()} | {:unwritable, term()}}
  def acquire(dir, mode) when mode in [:desktop, :headless] do
    path = Path.join(dir, @file_name)

    holder = %{
      pid: os_pid(),
      mode: mode,
      token: token(),
      at: DateTime.to_iso8601(DateTime.utc_now())
    }

    with :ok <- File.mkdir_p(dir),
         {:error, :eexist} <- write_exclusive(path, holder) do
      contend(path, holder, read(path))
    else
      {:ok, holder} -> {:ok, holder}
      {:error, reason} -> {:error, {:unwritable, reason}}
    end
  end

  # The file exists. A live holder is refused by name; a dead one is taken over; a file that
  # cannot be read is a holder that cannot be named, and is refused.
  defp contend(path, holder, {:ok, %{pid: pid} = existing}) do
    if alive?(pid), do: {:error, {:held, existing}}, else: take_over(path, holder)
  end

  defp contend(_path, _holder, {:error, reason}) do
    {:error, {:held, %{pid: 0, mode: :unknown, token: "unreadable: #{inspect(reason)}", at: ""}}}
  end

  @doc "Releases the lock file if this process's token wrote it. Idempotent."
  @spec release(Path.t(), holder()) :: :ok
  def release(dir, %{token: token}) do
    path = Path.join(dir, @file_name)

    case read(path) do
      {:ok, %{token: ^token}} -> File.rm(path) |> then(fn _ -> :ok end)
      _ -> :ok
    end
  end

  @doc "Reads the holder recorded in `dir`, if any."
  @spec holder(Path.t()) :: {:ok, holder()} | {:error, term()}
  def holder(dir), do: read(Path.join(dir, @file_name))

  ## Server

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    mode = Keyword.fetch!(opts, :mode)

    case acquire(dir, mode) do
      {:ok, holder} ->
        Process.flag(:trap_exit, true)
        {:ok, %{dir: dir, holder: holder}}

      {:error, {:held, %{pid: pid, mode: held_mode}}} ->
        {:stop,
         {:data_dir_held,
          "#{dir} is held by OS pid #{pid} in #{held_mode} mode; refusing to start and touching no database file"}}

      {:error, {:unwritable, reason}} ->
        {:stop,
         {:data_dir_unwritable, "cannot write #{Path.join(dir, @file_name)}: #{inspect(reason)}"}}
    end
  end

  @impl true
  def terminate(_reason, %{dir: dir, holder: holder}), do: release(dir, holder)

  ## Internals

  defp write_exclusive(path, holder) do
    case :file.open(String.to_charlist(path), [:write, :exclusive, :binary]) do
      {:ok, io} ->
        :ok = :file.write(io, encode(holder))
        :ok = :file.close(io)
        {:ok, holder}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp take_over(path, holder) do
    case File.write(path, encode(holder)) do
      :ok -> {:ok, holder}
      {:error, reason} -> {:error, {:unwritable, reason}}
    end
  end

  # One line per field, no JSON library in the boot path.
  defp encode(%{pid: pid, mode: mode, token: token, at: at}),
    do: "pid #{pid}\nmode #{mode}\ntoken #{token}\nat #{at}\n"

  defp read(path) do
    with {:ok, body} <- File.read(path),
         %{"pid" => pid, "mode" => mode, "token" => token, "at" => at} <- parse(body),
         {pid_int, ""} <- Integer.parse(pid),
         true <- mode in ["desktop", "headless"] do
      {:ok, %{pid: pid_int, mode: String.to_existing_atom(mode), token: token, at: at}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  defp parse(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, " ", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Map.new(fn [k, v] -> {k, v} end)
  end

  defp os_pid, do: String.to_integer(System.pid())

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  # Liveness of an OS pid. Linux answers through /proc; anywhere else this says "alive", so a
  # stale file from a crashed holder is refused rather than silently taken over. That is
  # the safe direction and the message names the pid to remove it by hand.
  defp alive?(pid) do
    case :os.type() do
      {:unix, :linux} -> File.dir?("/proc/#{pid}")
      _ -> true
    end
  end
end
