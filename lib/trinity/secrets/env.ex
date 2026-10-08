# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Secrets.Env do
  @moduledoc """
  The environment as a source of secrets (slice 011's only source; slice 100's fallback). Read
  only: a process cannot persist a variable for its next run, so there is no `store`.
  """

  @doc "The variable's value, or `{:error, :not_found}` when unset or empty."
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def fetch(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :not_found}
    end
  end
end
