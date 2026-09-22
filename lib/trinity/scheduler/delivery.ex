# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Scheduler.Delivery do
  @moduledoc """
  Where a finished run goes (slice 050). One implementation ships here, `Desktop`: the run is
  marked delivered and broadcast, and the tasks page shows it until the owner marks it seen.
  Gateways add implementations at 070; a task's `deliver_to` names one by `"kind"`, and the
  worker resolves it through `for/1`.
  """

  alias Trinity.Scheduler.{Run, Task}

  @doc "Delivers a finished run of a task; the run comes back as updated."
  @callback deliver(Run.t(), Task.t()) :: {:ok, Run.t()} | {:error, term()}

  @doc "The implementation for a task's `deliver_to`; the desktop for anything unknown."
  @spec for(Task.t()) :: module()
  def for(%Task{deliver_to: %{"kind" => kind}}) do
    Application.get_env(:trinity, :deliveries, %{})
    |> Map.get(kind, __MODULE__.Desktop)
  end

  def for(%Task{}), do: __MODULE__.Desktop
end
