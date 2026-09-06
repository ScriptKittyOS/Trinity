# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Versions do
  @moduledoc """
  The machine-readable pin list — finding M6's single source of truth.

  `VERSIONS.md`'s tables are generated from this module by `mix versions.gen`, so the prose
  cannot drift from the checked data, and `mix versions.verify` compares it against `mix.lock`.
  Neither reads the markdown: those cells hold emoji, footnotes and phrases like "decided by
  Slice 059", and a parser over them breaks on the first edit, which is when it is needed.

  **Deviation from `SLICE.md`, recorded here and in NOTES.md.** The spec named `versions.exs`,
  a data file. A `.exs` data file has to be evaluated at runtime, and `Trinity.Credo.NoEvalOnModelOutput`
  forbids the whole evaluation family under `lib/`. A compiled module carries the same data,
  needs no evaluation, and is checked by the compiler as well.
  """

  @toolchain [
    %{
      name: "erlang",
      pin: "28.5.0.5",
      note:
        "Newest OTP present on all four Burrito targets. Measured at slice 000; see ADR-0005's second correction."
    },
    %{name: "elixir", pin: "1.20.4-otp-28", note: "Built-in type checker is part of the gate."}
  ]

  @deps [
    %{
      name: "boundary",
      pin: "~> 0.10",
      note:
        "Compile-time boundary enforcement. Enforces ONLY under --warnings-as-errors; measured at slice 000."
    },
    %{name: "credo", pin: "~> 1.7", note: "--strict in the gate; hosts the eval-family check."},
    %{name: "mox", pin: "~> 1.2", note: "Mocks for every behaviour."},
    %{name: "mix_audit", pin: "~> 2.1", note: "Known vulnerabilities in the lock."},
    %{
      name: "sobelow",
      pin: "~> 0.15",
      note: "Phoenix security lint, blocking with a committed skip list."
    },
    %{name: "ex_doc", pin: "~> 0.38", note: "Docs."},
    %{name: "nimble_options", pin: "~> 1.1", note: "Option validation for behaviours."}
  ]

  @doc "Toolchain pins: the things `.tool-versions` fixes."
  @spec toolchain() :: [%{name: String.t(), pin: String.t(), note: String.t()}]
  def toolchain, do: @toolchain

  @doc "Dependency pins that `mix.lock` must satisfy."
  @spec deps() :: [%{name: String.t(), pin: String.t(), note: String.t()}]
  def deps, do: @deps
end
