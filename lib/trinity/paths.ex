# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Paths do
  @moduledoc """
  Where the packaged app keeps its data on each OS.

  A Burrito binary is launched by a double-click with no environment prepared for it, so it
  cannot ask for `DATABASE_PATH` the way `config/runtime.exs` does today — it has to work out
  where its own data lives. This module is that, and nothing else: no schema, no repo, no
  domain code.

  The OS is a parameter, not a global. `:os.type/0` and `System.get_env/1` are read once in the
  arity-0 wrappers and passed in, so every branch is reachable from a test on this Linux
  machine — which matters here, because the two branches that cannot be run on the owner's only
  machine are exactly the two that ship to users.

  ## FIRST PASS — the red for slice 001 line 4

  This version resolves one root for every OS. `test/paths_test.exs` fails on the macOS and
  Windows branches against it, which is the point: it demonstrates that the test discriminates
  between the branches rather than passing on whatever the host happens to be.
  """

  @app_dir_unix "trinity"

  @type os_type :: {:unix, atom()} | {:win32, atom()}
  @type getenv :: (String.t() -> String.t() | nil)

  @doc "The data directory for this machine, created if it does not exist."
  @spec data_dir() :: String.t()
  def data_dir, do: data_dir(:os.type(), &System.get_env/1)

  @doc """
  The data directory for `os_type`, resolving environment variables through `getenv`.
  """
  @spec data_dir(os_type(), getenv()) :: String.t()
  def data_dir(_os_type, getenv) do
    root = getenv.("XDG_DATA_HOME") || Path.join(getenv.("HOME") || ".", ".local/share")
    Path.join(root, @app_dir_unix)
  end
end
