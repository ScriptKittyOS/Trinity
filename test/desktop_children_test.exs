# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule DesktopChildrenTest do
  @moduledoc """
  Slice 001 G4. `mix ex_tauri.install` added `ExTauri.ShutdownManager` to the supervision tree
  unconditionally while `ex_tauri` was `only: :dev`, so the application could not start under
  `MIX_ENV=test` or `MIX_ENV=prod`.

  The fix has two halves and this asserts both, because either one alone is a trap:

    * the dependency is available in every environment, so the packaged binary carries the
      heartbeat. If someone re-adds `only: :dev` the release loses its shutdown mechanism and
      nothing else notices: finding F1's failure mode, shipped.
    * the child is excluded from `:test` at compile time, not by asking whether the module
      happens to be loaded. A `Code.ensure_loaded?/1` guard returns the same empty list whether
      the exclusion was intended or the dependency vanished.
  """
  use ExUnit.Case, async: true

  describe "Trinity.Application.desktop_children/0" do
    test "is empty under :test" do
      assert Trinity.Application.desktop_children() == []
      assert Mix.env() == :test
    end
  end

  describe "the dependency that makes the heartbeat shippable" do
    test "ex_tauri is declared for every environment, not only :dev" do
      dep =
        Mix.Project.config()[:deps]
        |> Enum.find(&(elem(&1, 0) == :ex_tauri))

      assert dep, "ex_tauri is not declared at all"

      opts =
        case dep do
          {_name, _req} -> []
          {_name, _req, opts} -> opts
        end

      refute Keyword.has_key?(opts, :only),
             "ex_tauri carries #{inspect(opts)}. ExTauri.ShutdownManager is the sidecar " <>
               "heartbeat and must exist in the packaged binary; an env-restricted " <>
               "dependency ships a release with no way to learn its window closed."
    end

    test "the exclusion is compile-time, so a missing dependency cannot masquerade as it" do
      # In :test the child list is empty *and* the module is genuinely absent from the app's
      # own children by construction. Assert the module exists as a dependency even here, so
      # that "empty" means "excluded on purpose" rather than "not installed".
      assert Code.ensure_loaded?(ExTauri.ShutdownManager),
             "ex_tauri is not compiled in :test, so an empty desktop_children/0 would be " <>
               "indistinguishable from a dropped dependency"
    end
  end
end
