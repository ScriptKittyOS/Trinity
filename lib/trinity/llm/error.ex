# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Error do
  @moduledoc """
  A provider failure with one bit that matters to the caller: whether trying again could help.
  Timeouts, rate limits, server errors and refused connections are transient; everything else
  (a bad key, an unknown model, a malformed request) is not and is returned at once.
  """

  @type t :: %__MODULE__{transient?: boolean(), reason: term(), status: non_neg_integer() | nil}
  defexception [:reason, :status, transient?: false]

  @impl true
  def message(%__MODULE__{transient?: t, status: status, reason: reason}) do
    kind = if t, do: "transient", else: "permanent"
    "#{kind} LLM error#{if status, do: " (HTTP #{status})", else: ""}: #{inspect(reason)}"
  end

  @doc "Classifies an HTTP status: 408, 425, 429 and 5xx are transient."
  @spec from_status(non_neg_integer(), term()) :: t()
  def from_status(status, reason) do
    %__MODULE__{
      status: status,
      reason: reason,
      transient?: status in [408, 425, 429] or status >= 500
    }
  end

  @doc "A transient error with no status: a timeout, a closed or refused connection."
  @spec transient(term()) :: t()
  def transient(reason), do: %__MODULE__{reason: reason, transient?: true}

  @doc "A permanent error with no status."
  @spec permanent(term()) :: t()
  def permanent(reason), do: %__MODULE__{reason: reason, transient?: false}
end
