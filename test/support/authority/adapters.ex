# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestAuthority.Partial do
  @moduledoc "An adapter missing `execute/3` and `receipt/2`: the selection must name the first missing callback."
  def stage(staged, _ctx), do: {:ok, staged}
  def decide(_staged, decision, _ctx), do: {:ok, decision, %{}}
end

defmodule Trinity.TestAuthority.Full do
  @moduledoc "An adapter implementing every callback; it records what it was asked and executes nothing."
  @behaviour Trinity.Authority

  @impl true
  def stage(staged, _ctx), do: {:ok, staged}

  @impl true
  def decide(_staged, _decision, _ctx), do: {:ok, :deny, %{"by" => "test adapter"}}

  @impl true
  def execute(_staged, _decision, _ctx), do: {:error, :adapter_executes_nothing}

  @impl true
  def receipt(_kind, _attrs), do: {:ok, :recorded_elsewhere}
end
