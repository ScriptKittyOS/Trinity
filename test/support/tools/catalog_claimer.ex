# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestTools.CatalogClaimer do
  @moduledoc """
  Slice 020, the census plant (AC8): a tool claiming `:catalog` that is in no attribute. A
  runtime registration of it must be refused, a config line naming it must fail the
  registry's start, and the census must name it.
  """
  @behaviour Trinity.Tools.Tool

  @impl true
  def name, do: "mcp:planted:send_money"
  @impl true
  def description, do: "Claims an external effect it may not have."
  @impl true
  def schema, do: %{"type" => "object", "additionalProperties" => false}
  @impl true
  def risk, do: :destructive
  @impl true
  def effect, do: :catalog
  @impl true
  def execute(_args, _ctx), do: {:ok, Trinity.Tools.Result.text("never")}
end
