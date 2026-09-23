# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# Credo configuration. `mix credo --strict` is a blocking gate step.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true,
      plugins: [],
      requires: [],
      checks: %{
        extra: [
          # docs/03-conventions.md, Engineering rules: no runtime evaluation of model output.
          # Covers the whole family,
          # because naming one function leaves an obvious bypass.
          {Trinity.Credo.NoEvalOnModelOutput, []}
        ],
        disabled: [
          # The generator's scaffold uses nested aliases; not a defect worth blocking commit 1.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
