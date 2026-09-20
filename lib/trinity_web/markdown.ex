# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Markdown do
  @moduledoc """
  Model output to HTML, and the only place it happens. Slice 013.

  `mdex` renders with raw HTML omitted (`unsafe: false`) and its default sanitizer on top, so a
  `<script>` in an answer is dropped and a `javascript:` href emptied; the measurement that chose
  it over the alternatives is in the slice's NOTES.md. With `streaming: true` an unfinished
  fragment (`**bold te`, an open fence) is completed before rendering, which is what the
  in-progress message uses; a finished message renders without it, once.
  """

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused (the same
  # measure `Trinity.Paths` takes, slice 001 line 4).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @extension [strikethrough: true, table: true, autolink: true, tasklist: true]

  @doc """
  The HTML for a markdown string, safe to mark raw. `streaming: true` completes an unfinished
  fragment first.
  """
  # sobelow_skip reason: XSS.Raw fires on every `raw/1`, low confidence. This is the one call
  # in the tree, on HTML the renderer produced with raw input HTML omitted and the sanitizer
  # applied, and `TrinityWeb.MarkdownTest` asserts a script tag and a javascript: href do not
  # survive. Scoped to the function rather than .sobelow-skips, which keys on file and line.
  @sobelow_skip ["XSS.Raw"]
  @spec to_html(String.t(), keyword()) :: Phoenix.HTML.safe()
  def to_html(markdown, opts \\ []) when is_binary(markdown) do
    options = [
      extension: @extension,
      render: [unsafe: false],
      sanitize: MDEx.Document.default_sanitize_options(),
      streaming: Keyword.get(opts, :streaming, false)
    ]

    case MDEx.to_html(markdown, options) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      # A parse failure is the renderer's, not the text's: show the text escaped rather than
      # nothing, so a message is never blank on screen.
      {:error, _} -> Phoenix.HTML.html_escape(markdown)
    end
  end
end
