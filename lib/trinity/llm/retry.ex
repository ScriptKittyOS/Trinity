# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Retry do
  @moduledoc """
  Retries a provider call on transient errors with exponential backoff; returns a permanent
  error at once. Slice 011 AC4. `attempts` and `base_ms` come from `config :trinity, :llm,
  retry: [attempts: 3, base_ms: 200]`; an opt overrides either for one call. The sleep is
  `base_ms * 2^n` with no jitter, which is enough for one desktop's rate limits and is written
  down so nobody expects more.
  """

  alias Trinity.LLM.Error

  @default_attempts 3
  @default_base_ms 200

  @doc "Runs `fun` up to `attempts` times while it returns a transient error."
  @spec run((-> {:ok, term()} | {:error, Error.t()}), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def run(fun, opts \\ []) do
    retry = Keyword.get(Application.get_env(:trinity, :llm, []), :retry, [])
    attempts = Keyword.get(opts, :attempts, Keyword.get(retry, :attempts, @default_attempts))
    base_ms = Keyword.get(opts, :base_ms, Keyword.get(retry, :base_ms, @default_base_ms))
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    attempt(fun, 1, attempts, base_ms, sleep)
  end

  defp attempt(fun, n, attempts, base_ms, sleep) do
    case fun.() do
      {:error, %Error{transient?: true}} when n < attempts ->
        sleep.(base_ms * Integer.pow(2, n - 1))
        attempt(fun, n + 1, attempts, base_ms, sleep)

      {:error, %Error{transient?: true} = error} ->
        {:error, %{error | reason: {:exhausted, attempts, error.reason}}}

      other ->
        other
    end
  end
end
