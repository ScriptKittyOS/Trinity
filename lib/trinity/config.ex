# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Config do
  @moduledoc """
  Secrets, read from one place. Slice 011: the environment. Slice 100: the OS keychain first and
  the environment second, through `Trinity.Secrets`; nothing else in the tree reads a key any
  other way.
  """

  @doc "The secret named by `env_var`, or a named error; never nil handed to a provider."
  @spec secret(String.t()) :: {:ok, String.t()} | {:error, {:missing_secret, String.t()}}
  def secret(env_var) when is_binary(env_var) do
    case Trinity.Secrets.fetch(env_var) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, {:missing_secret, env_var}}
    end
  end
end
