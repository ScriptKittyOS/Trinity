# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Alarm do
  @moduledoc """
  The failure that must sound outside the receipt stream (slice 024, the C1 resolution):
  a signer that cannot sign. Sets the OTP alarm `:trinity_receipts_signer` through
  `:alarm_handler` and emits `[:trinity, :receipts, :signer_unavailable]` with the reason,
  so an operator's telemetry sees it where no receipt can say it.
  """

  @alarm :trinity_receipts_signer
  @event [:trinity, :receipts, :signer_unavailable]

  @doc "The alarm id."
  @spec alarm_id() :: atom()
  def alarm_id, do: @alarm

  @doc "The telemetry event name."
  @spec event() :: [atom()]
  def event, do: @event

  @doc "Raises the alarm (idempotent) and emits the event."
  @spec signer_unavailable(term()) :: :ok
  def signer_unavailable(reason) do
    :alarm_handler.set_alarm({@alarm, reason})
    :telemetry.execute(@event, %{count: 1}, %{reason: reason})
    :ok
  end

  @doc "Clears the alarm once a signer signs again."
  @spec clear() :: :ok
  def clear do
    :alarm_handler.clear_alarm(@alarm)
    :ok
  end

  @doc "True while the alarm is set."
  @spec set?() :: boolean()
  def set?, do: Enum.any?(:alarm_handler.get_alarms(), fn {id, _} -> id == @alarm end)
end
