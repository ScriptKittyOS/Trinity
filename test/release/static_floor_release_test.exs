# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.StaticFloorReleaseTest do
  @moduledoc """
  Slice 133, AC8: a release assembled without the neural group boots, embeds and recalls
  through the static space, as a spawned process. `scripts/static_floor_release.sh` does the
  work (a prod build with `TRINITY_WITHOUT_ML=1` in a build root of its own, the headless release,
  the group's absence from its `lib/`, a boot with two memories written and one recalled); this
  runs it and asserts on the lines it prints.

  `:static_weights`: the release reads the artifact from `TRINITY_STATIC_MODEL_DIR`. It compiles
  a whole prod tree the first time, which takes minutes.
  """
  use ExUnit.Case, async: false

  @moduletag :static_weights
  @moduletag timeout: 1_800_000

  defp line(out, prefix),
    do: out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, prefix))

  test "AC8: without nx, exla, xla, axon, bumblebee and tokenizers, the release boots, embeds and recalls" do
    dir = Trinity.StaticWeights.dir!()

    {out, status} =
      System.cmd("sh", ["scripts/static_floor_release.sh"],
        env: [
          {"TRINITY_STATIC_MODEL_DIR", dir},
          {"MIX_ENV", nil},
          {"FLOOR_BUILD_ROOT", System.get_env("FLOOR_BUILD_ROOT", "../_build_floor")}
        ],
        stderr_to_stdout: true
      )

    lines =
      ~w(FLOOR_GROUP FLOOR_EMBEDDER FLOOR_NX_LOADABLE FLOOR_STATUS FLOOR_SPACE FLOOR_RECALL)
      |> Enum.map_join("\n", &line(out, &1))

    IO.puts("\n" <> lines)
    assert status == 0, String.slice(out, -4000, 4000)
    assert line(out, "FLOOR_GROUP") == "FLOOR_GROUP_ABSENT"
    assert line(out, "FLOOR_EMBEDDER") == "FLOOR_EMBEDDER Trinity.Memory.Embedders.Static"
    assert line(out, "FLOOR_NX_LOADABLE") == "FLOOR_NX_LOADABLE false"
    assert line(out, "FLOOR_STATUS") == "FLOOR_STATUS :on"

    assert line(out, "FLOOR_SPACE") ==
             "FLOOR_SPACE #{Trinity.Memory.Space.id(Trinity.Memory.Embedders.Static.space())} int8"

    assert line(out, "FLOOR_RECALL") =~
             ~s({:memory, [:vector], "The person's dog is called Rex."})
  end
end
