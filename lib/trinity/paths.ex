# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Paths do
  @moduledoc """
  Where the packaged app keeps its data on each OS.

  A Burrito binary is launched by a double-click with no environment prepared for it, so it
  cannot ask for `DATABASE_PATH` the way `config/runtime.exs` does today — it has to work out
  where its own data lives. This module is that, and nothing else: no schema, no repo, no
  domain code.

  ## The OS is a parameter, not a global

  `:os.type/0` and `System.get_env/1` are read once, in the arity-0 wrappers, and passed into
  the arity-2 functions. Every branch is therefore reachable from a test on this Linux machine
  — which matters here, because the two branches that cannot be run on the owner's only machine
  are exactly the two that ship to users. `test/paths_test.exs` drives all three from a stub and
  asserts they do not collapse into one, which is how the first pass of this module failed.

  ## The roots

  | OS      | Data                                      | Source |
  |---------|-------------------------------------------|--------|
  | Linux   | `$XDG_DATA_HOME/trinity`, else `~/.local/share/trinity` | XDG Base Directory |
  | macOS   | `~/Library/Application Support/Trinity`   | Apple File System Programming Guide |
  | Windows | `%APPDATA%\\Trinity`                       | Known Folders, `FOLDERID_RoamingAppData` |

  These are the three `SLICE.md` names. The case difference is not a slip: `trinity` lower-case
  is the XDG convention, `Trinity` capitalised is the macOS and Windows convention, and a
  packaged app that ignores either looks wrong to the person whose disk it is on.
  """

  # Sobelow reads `@sobelow_skip` out of the source AST; the compiler never sees it used and
  # warns "set but never used", which `mix gate`'s `--warnings-as-errors` turns into a failure.
  # Registering it as a persisted attribute makes it a real attribute to the compiler without
  # changing what sobelow reads. Measured at slice 001 line 4.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @unix_name "trinity"
  @display_name "Trinity"

  @type os_type :: {:unix, atom()} | {:win32, atom()}
  @type getenv :: (String.t() -> String.t() | nil)

  @doc """
  The data directory for this machine.

  Reads `:os.type/0` and the real environment. Does not create the directory: see
  `ensure_data_dir/0`.
  """
  @spec data_dir() :: String.t()
  def data_dir, do: data_dir(:os.type(), &System.get_env/1)

  @doc """
  The data directory for `os_type`, resolving environment variables through `getenv`.

  `getenv` returns `nil` for an unset variable, exactly like `System.get_env/1`.
  """
  @spec data_dir(os_type(), getenv()) :: String.t()
  def data_dir({:win32, _}, getenv) do
    root = getenv.("APPDATA") || Path.join(home(getenv), "AppData\\Roaming")
    root <> "\\" <> @display_name
  end

  def data_dir({:unix, :darwin}, getenv) do
    Path.join([home(getenv), "Library", "Application Support", @display_name])
  end

  def data_dir({:unix, _}, getenv) do
    root = getenv.("XDG_DATA_HOME") || Path.join(home(getenv), ".local/share")
    Path.join(root, @unix_name)
  end

  @doc """
  `data_dir/0`, with the directory created if it is absent. Returns the path.
  """
  # sobelow_skip reason: Traversal.FileModule fires because `dir` is a variable rather than a
  # literal. It is not user input: `data_dir/0` reads `:os.type/0` and HOME/XDG_DATA_HOME/APPDATA
  # and joins a constant app name. An attacker who can set this process's environment has already
  # won by a shorter route than a path here. Scoped to this function rather than put in
  # .sobelow-skips because that file keys on file AND line, so any edit above this point silently
  # reopens the finding — measured at slice 000 when SPDX headers moved router.ex:10 to :12.
  @sobelow_skip ["Traversal.FileModule"]
  @spec ensure_data_dir() :: String.t()
  def ensure_data_dir do
    dir = data_dir()
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  The SQLite file the packaged app opens, under `data_dir/0`.

  `config/runtime.exs` demands `DATABASE_PATH` and raises without it, which is right for a
  server deployment and wrong for a double-clicked binary. This is what the packaged boot path
  falls back to.
  """
  @spec database_path() :: String.t()
  def database_path, do: Path.join(ensure_data_dir(), "trinity.db")

  @spec home(getenv()) :: String.t()
  defp home(getenv) do
    getenv.("HOME") || getenv.("USERPROFILE") || "."
  end
end
