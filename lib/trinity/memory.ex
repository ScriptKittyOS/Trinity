# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory do
  @moduledoc """
  The memory context. Slice 023 opens it with token estimation and compaction; slices 030
  to 032 add the tiers, the search and the semantic recall. It depends on the LLM and on the
  core, never on Sessions: the Session calls it and writes what it returns.
  """
  use Boundary,
    deps: [Trinity, Trinity.LLM],
    exports: [
      Tokens,
      Compactor,
      Search,
      AlwaysOn,
      Budget,
      Consolidator,
      Entry,
      Proposal,
      Change,
      Embedder,
      Embedders.Bumblebee,
      Embedders.Fake,
      # Slice 133: the static floor, its weights file and tokenizer, and the space identity.
      Embedders.Static,
      StaticArtifact,
      WordPiece,
      Space,
      Spaces,
      SpaceRow,
      Vector,
      Scorer,
      EmbedderConfig,
      ReEmbedWorker,
      Observer,
      Retriever,
      Semantic,
      Supervisor,
      VectorStore
    ]
end
