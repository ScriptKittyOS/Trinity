# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.FormatTest do
  @moduledoc """
  Slice 070: the default formatting every adapter delegates to. Chunking splits at the latest
  boundary that fits and never past the limit; a split code fence is closed and re-opened; a
  channel without markdown is given the markers removed rather than shown; an approval renders
  with the two commands a person can type.
  """
  use ExUnit.Case, async: true

  alias Trinity.Gateways.Format
  alias Trinity.Permissions.Approval

  @caps %{markdown: true, images: false, buttons: false, edits: true, max_length: 40}

  test "a message inside the limit is one chunk, unchanged" do
    assert Format.chunk("short enough", 40) == ["short enough"]
    assert Format.format("short enough", @caps) == ["short enough"]
  end

  test "chunks never exceed the limit and prefer the latest paragraph, line, then word boundary" do
    paragraphs = "#{String.duplicate("a", 20)}\n\n#{String.duplicate("b", 20)}"
    assert [first, second] = Format.chunk(paragraphs, 30)
    assert first == String.duplicate("a", 20)
    assert second == String.duplicate("b", 20)

    lines = "#{String.duplicate("a", 20)}\n#{String.duplicate("b", 20)}"
    assert [^first, ^second] = Format.chunk(lines, 30)

    words = String.duplicate("word ", 20)
    chunks = Format.chunk(words, 30)
    assert Enum.all?(chunks, &(String.length(&1) <= 30))

    assert chunks |> Enum.join(" ") |> String.replace(~r/\s+/, " ") |> String.trim() ==
             String.trim(words)
  end

  test "a single word longer than the limit is cut, because there is no boundary to prefer" do
    long = String.duplicate("x", 95)
    chunks = Format.chunk(long, 40)
    assert Enum.map(chunks, &String.length/1) == [40, 40, 15]
    assert Enum.join(chunks) == long
  end

  test "a code fence split across chunks is closed and re-opened, so the rest is not swallowed" do
    code = "```\n" <> String.duplicate("line of code\n", 8) <> "```"
    chunks = Format.chunk(code, 60)
    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.length(&1) <= 60 + 8))

    # Every chunk holds an even number of fences: none of them leaves a block open.
    for chunk <- chunks do
      assert chunk |> String.split("```") |> length() |> rem(2) == 1,
             "unbalanced fence in #{chunk}"
    end
  end

  test "a channel without markdown is given the markers removed, not shown" do
    caps = %{@caps | markdown: false, max_length: 4_000}
    text = "# Heading\n\nSome **bold** and *italic* and `code`.\n\n- one\n- two"
    assert [plain] = Format.format(text, caps)
    assert plain == "Heading\n\nSome bold and italic and code.\n\n• one\n• two"
    refute plain =~ "**"
    refute plain =~ "#"
  end

  test "an approval renders with its tool, its tier and the two commands that answer it" do
    approval = %Approval{
      id: "0198f0c0-1111-2222-3333-444455556666",
      tool: "write_note",
      risk: "write",
      args: %{"path" => "notes/today.md", "body" => String.duplicate("x", 80)}
    }

    assert {:message, text} = Format.render_approval(approval, %{@caps | max_length: 4_000})
    assert text =~ "Approval needed: write_note (write)"
    assert text =~ "path=notes/today.md"
    assert text =~ "/approve 0198f0c0"
    assert text =~ "/deny 0198f0c0"
    # The arguments are summarised, never pasted whole.
    refute text =~ String.duplicate("x", 45)
  end
end
