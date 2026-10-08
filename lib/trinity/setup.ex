# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Setup do
  @moduledoc """
  Whether this installation still needs its first-run setup (slice 100, AC11).

  Measured, not assumed: setup is needed while it has not been completed **and** the default
  model cannot answer, because it needs a key that neither the keychain nor the environment has
  (or there is no default model at all). A developer with the key in the environment, or a
  registry whose default needs no key (the suite's scripted model), is never sent to setup; an
  owner who completed it once is not sent back if a key later goes missing (the turn's own error
  says which key).
  """

  alias Trinity.{Config, LLM, Settings}

  @doc "True while the first-run setup has something to do."
  @spec needed?() :: boolean()
  def needed?, do: Settings.get(:onboarded_at) == nil and not default_model_ready?()

  @doc "Whether the default model has what it needs to answer: a key, if it names one."
  @spec default_model_ready?() :: boolean()
  def default_model_ready? do
    case LLM.Registry.lookup(LLM.default_model()) do
      {:ok, entry} -> model_ready?(entry)
      {:error, _} -> false
    end
  end

  @doc "Whether a registry entry has its key (or needs none)."
  @spec model_ready?(map()) :: boolean()
  def model_ready?(entry) do
    case Map.get(entry, :api_key_env) do
      nil -> true
      name -> match?({:ok, _}, Config.secret(name))
    end
  end

  @doc "Marks the setup done and makes `model_id` the default model."
  @spec complete(String.t()) :: :ok | {:error, term()}
  def complete(model_id) do
    with :ok <- Settings.put(:default_model, model_id) do
      Settings.put(:onboarded_at, DateTime.utc_now() |> DateTime.to_iso8601())
    end
  end
end
