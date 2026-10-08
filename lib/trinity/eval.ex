# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Eval do
  @moduledoc """
  The memory-recall eval (slice 133, AC14): its corpus generator (`Trinity.Eval.Corpus`), its
  files, audit and label freeze (`Trinity.Eval.Labels`), and its scored run
  (`Trinity.Eval.MemoryRun`), driven by `mix trinity.eval.corpus`, `mix trinity.eval.freeze` and
  `mix trinity.eval.memory`. A boundary of its own: it reads the memory context's embedders,
  scorer and search, and nothing in the product calls it.
  """
  use Boundary, top_level?: true, deps: [Trinity], exports: [Corpus, Labels, MemoryRun]
end
