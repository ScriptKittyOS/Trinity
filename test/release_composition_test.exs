# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule ReleaseCompositionTest do
  @moduledoc """
  Slice 133, AC12. The Linux Burrito bundle carries no exla. The release's applications are
  computed in `mix.exs`, so this asserts on the function `releases/0` calls for the desktop
  release, for each target `package.yml` builds. The artifact's size and its
  `TRINITY_SMOKE_EXLA` line are the package run's half and are cited in the proof.
  """
  use ExUnit.Case, async: true

  test "the Linux bundle leaves exla out" do
    linux = Trinity.MixProject.desktop_release_applications("linux_x86_64")
    refute Keyword.has_key?(linux, :exla)
  end

  test "macOS and Windows bundles, and a build with no target, keep what the host declares" do
    for target <- ["macos_aarch64", "windows_x86_64", nil] do
      assert Trinity.MixProject.desktop_release_applications(target) == headless()
    end
  end

  test "the headless release still carries exla where the host declares it" do
    case :os.type() do
      {:win32, _} -> assert headless() == []
      _ -> assert headless()[:exla] == :load
    end
  end

  defp headless, do: Trinity.MixProject.project()[:releases][:headless][:applications]
end
