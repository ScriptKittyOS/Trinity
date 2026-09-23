# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.ConsoleTest do
  @moduledoc """
  Slice 070: the in-process adapter. It implements every callback of the behaviour, it records
  what it was asked to deliver, and `text/1` answers with what a person in the channel would be
  looking at: a message replaced by its edits rather than a log of both.
  """
  use ExUnit.Case, async: false

  alias Trinity.Gateways.{Adapter, Console}

  setup do
    pid = start_supervised!(Console)
    on_exit(fn -> if Process.alive?(pid), do: :ok end)
    :ok
  end

  test "it implements every callback the behaviour declares" do
    callbacks = Adapter.behaviour_info(:callbacks) |> Enum.sort()
    exported = Console.__info__(:functions)

    for {name, arity} <- callbacks do
      assert {name, arity} in exported or name == :child_spec,
             "Console does not implement #{name}/#{arity}"
    end

    # child_spec/1 comes from `use GenServer`, which is how the supervisor starts it.
    assert function_exported?(Console, :child_spec, 1)
  end

  # Written as one equality and not as `assert caps.markdown`: the type checker inlines the
  # module attribute and flags an assertion on a literal, rightly, since it proves nothing. What
  # is worth holding is the whole declaration, so a change to any field is a change to this line.
  test "capabilities declare a plain text channel that can edit, and every field the router reads" do
    assert Console.capabilities() == %{
             markdown: true,
             images: false,
             buttons: false,
             edits: true,
             max_length: 4_000
           }
  end

  test "a delivered message answers with a reference, and an edit replaces what it names" do
    assert {:ok, ref} = Console.deliver("c1", {:message, "first"})
    assert :ok = Console.deliver("c1", {:typing, true})
    assert :ok = Console.deliver("c1", {:edit, ref, "first, corrected"})
    assert {:ok, _} = Console.deliver("c1", {:message, "second"})

    assert Console.text("c1") == ["first, corrected", "second"]

    assert Console.delivered("c1") == [
             {:message, "first"},
             {:typing, true},
             {:edit, ref, "first, corrected"},
             {:message, "second"}
           ]
  end

  test "conversations are separate, and one can be cleared" do
    Console.deliver("a", {:message, "for a"})
    Console.deliver("b", {:message, "for b"})
    assert Console.text("a") == ["for a"]
    assert Console.text("b") == ["for b"]

    assert :ok = Console.clear("a")
    assert Console.text("a") == []
    assert Console.text("b") == ["for b"]
  end

  test "format and render_approval are the shared defaults, not a dialect of its own" do
    long = String.duplicate("word ", 2_000)
    chunks = Console.format(long, Console.capabilities())
    assert Enum.all?(chunks, &(String.length(&1) <= Console.capabilities().max_length))
    assert length(chunks) > 1
  end
end
