# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Supervisor do
  @moduledoc """
  Starts the receipts side (slice 024): selects the signer and its key once (`KeyCustody.boot!/1`)
  before any writer exists, then the writer supervisor; the boot receipt is
  `Trinity.Effects.Boot`, the application's next child. A failed
  selection is logged and the alarm set; the tree still starts, and every effect is denied
  until a signer is available (the C1 resolution: fail closed, never unsigned).
  """
  use Supervisor

  require Logger

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case Trinity.Receipts.KeyCustody.boot!() do
      {:ok, %{algorithm: alg, key_id: key_id}} ->
        Logger.info("receipts: signer #{alg}, key #{key_id}")

      {:error, reason} ->
        Logger.error(
          "receipts: no signer: #{inspect(reason)}; every effect is denied until one is"
        )

        Trinity.Receipts.Alarm.signer_unavailable(reason)
    end

    children = [
      {DynamicSupervisor, name: Trinity.Receipts.WriterSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
