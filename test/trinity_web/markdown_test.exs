# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.MarkdownTest do
  @moduledoc "Slice 013 line 2: the renderer drops raw HTML, empties script hrefs, completes fragments, and is pure."
  use ExUnit.Case, async: true

  alias TrinityWeb.Markdown

  defp html(md, opts \\ []), do: md |> Markdown.to_html(opts) |> Phoenix.HTML.safe_to_string()

  test "raw HTML in the answer is omitted, block and inline" do
    out = html("before\n\n<script>alert(1)</script>\n\n<b onclick=\"x()\">bold</b> after")
    refute out =~ "<script"
    refute out =~ "onclick"
    assert out =~ "before"
    assert out =~ "bold"
  end

  test "a javascript: href is emptied and ordinary links get rel=noopener" do
    out = html("[js](javascript:alert(1)) and [ok](https://example.com)")
    refute out =~ "javascript:"
    assert out =~ ~s(href="https://example.com")
    assert out =~ "noopener"
  end

  test "markdown structure renders: emphasis, code, list, table, fence" do
    out = html("**b** `c`\n\n- one\n\n| a |\n|---|\n| 1 |\n\n```elixir\nx\n```\n")
    assert out =~ "<strong>b</strong>"
    assert out =~ "<code>c</code>"
    assert out =~ "<li>one</li>"
    assert out =~ "<table>"
    assert out =~ ~s(<code class="language-elixir">)
  end

  test "streaming completes an unfinished fragment; a finished render is not touched" do
    assert html("Some **bold te", streaming: true) =~ "<strong>bold te</strong>"
    assert html("```elixir\ndef x, do", streaming: true) =~ "<pre>"
    refute html("Some **bold te") =~ "<strong>"
  end

  test "the same text renders the same HTML twice" do
    md = "# T\n\ntext *em*\n"
    assert html(md) == html(md)
  end
end
