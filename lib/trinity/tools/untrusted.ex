# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Untrusted do
  @moduledoc """
  What every tool result that came from outside the app goes through. Slice 022. `wrap/2`
  makes a `Trinity.Content.Part` tainted `:untrusted` with its digest; the prompt builder is
  what renders it inside an `<untrusted>` block and states the rule, so the wrapping is
  provenance on the record rather than a string a tool could forget.
  """

  alias Trinity.Content.Part
  alias Trinity.Tools.Result

  @doc "An untrusted part over `text` from `origin` (a tool name) at `source_ref`."
  @spec wrap(String.t(), keyword()) :: Part.t()
  def wrap(text, opts) when is_binary(text) do
    Part.new(text,
      origin: "tool:" <> Keyword.fetch!(opts, :tool),
      source_ref: Keyword.get(opts, :source_ref),
      taint: :untrusted
    )
  end

  @doc "A result whose content is one untrusted part."
  @spec result(String.t(), keyword()) :: Result.t()
  def result(text, opts) do
    part = wrap(text, opts)
    %Result{content: text, parts: [part], meta: Keyword.get(opts, :meta, %{})}
  end
end
