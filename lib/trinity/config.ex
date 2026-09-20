# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Config do
  @moduledoc """
  Secrets, read from one place. Slice 011: the environment. Slice 100 adds the OS keychain
  behind the same function, and nothing else in the tree reads a key any other way.
  """

  @doc "The secret named by `env_var`, or a named error; never nil handed to a provider."
  @spec secret(String.t()) :: {:ok, String.t()} | {:error, {:missing_secret, String.t()}}
  def secret(env_var) when is_binary(env_var) do
    case System.get_env(env_var) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_secret, env_var}}
    end
  end
end
