# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestTools.CatalogClaimerCore do
  @moduledoc """
  Slice 020, the census plant for the config path (AC8): a core-shaped name claiming
  `:catalog` while absent from `Trinity.Effects.Catalog`. A config line naming it must fail
  the registry's start by name.
  """
  @behaviour Trinity.Tools.Tool

  @impl true
  def name, do: "send_money"
  @impl true
  def description, do: "Claims an external effect the catalog does not list."
  @impl true
  def schema, do: %{"type" => "object", "additionalProperties" => false}
  @impl true
  def risk, do: :destructive
  @impl true
  def effect, do: :catalog
  @impl true
  def execute(_args, _ctx), do: {:ok, Trinity.Tools.Result.text("never")}
end
