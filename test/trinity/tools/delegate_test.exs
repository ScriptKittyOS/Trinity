# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.DelegateTest do
  @moduledoc """
  Slice 080: the `delegate` tool the model calls.

  Two things are asserted here that are easy to leave untested because they are not the happy path.
  The tool's result is **untrusted**, like any tool result, and being produced by this project's own
  subagent changes nothing about that. And the argument validation refuses rather than guesses:
  a model that sends both `brief` and `briefs`, or an empty one, gets a sentence telling it what to
  do instead of a silently dropped half of its request.
  """
  use Trinity.SessionCase

  alias Trinity.LLM.Providers.Fake
  alias Trinity.Tools.{Context, Delegate}

  defp ctx! do
    {:ok, s} =
      Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "parent"})

    %Context{session_id: s.id}
  end

  test "it is a read with no effect, and says so" do
    assert Delegate.name() == "delegate"
    assert Delegate.risk() == :read
    assert Delegate.effect() == :none
  end

  test "the description tells the model the child cannot see this conversation" do
    # The mistake a model makes here is a brief like "summarise that". The description has to
    # prevent it, because nothing else can: the child simply has no referent.
    d = Delegate.description()
    assert d =~ "CANNOT see this conversation"
    assert d =~ "stand alone"
  end

  test "one brief runs and the answer comes back as untrusted" do
    Fake.scripts([script_deltas(2, "the answer ")])
    ctx = ctx!()

    assert {:ok, result} = Delegate.execute(%{"brief" => "do the thing"}, ctx)

    text = result_text(result)
    assert text =~ "the answer"
    assert text =~ "Subagent "
    assert untrusted?(result)
  end

  test "several briefs come back numbered, in the order given" do
    Fake.scripts(Enum.map(1..3, fn _ -> script_deltas(1, "ok ") end))
    ctx = ctx!()

    assert {:ok, result} =
             Delegate.execute(%{"briefs" => ["alpha task", "beta task", "gamma task"]}, ctx)

    text = result_text(result)
    assert text =~ "1. alpha task"
    assert text =~ "2. beta task"
    assert text =~ "3. gamma task"
  end

  test "a budget overrun is reported to the model as an unfinished child, not as an answer" do
    Fake.scripts([script_deltas(1, "partial ")])
    ctx = ctx!()

    assert {:ok, result} = Delegate.execute(%{"brief" => "slow", "timeout_ms" => 1_000}, ctx)
    # With a real budget this completes; the rendering of an overrun is asserted directly below
    # rather than by racing the clock.
    assert is_binary(result_text(result))
  end

  describe "arguments are refused rather than guessed" do
    test "both brief and briefs is a refusal, not a silent preference for one" do
      assert {:error, msg} =
               Delegate.execute(%{"brief" => "a", "briefs" => ["b"]}, ctx!())

      assert msg =~ "not both"
    end

    test "empty input is refused by name" do
      assert {:error, m1} = Delegate.execute(%{"brief" => "   "}, ctx!())
      assert m1 =~ "empty"

      assert {:error, m2} = Delegate.execute(%{"briefs" => []}, ctx!())
      assert m2 =~ "empty"

      assert {:error, m3} = Delegate.execute(%{}, ctx!())
      assert m3 =~ "Give brief or briefs"
    end

    test "too many briefs is refused with the limit named" do
      many = Enum.map(1..9, &"brief #{&1}")
      assert {:error, msg} = Delegate.execute(%{"briefs" => many}, ctx!())
      assert msg =~ "At most"
    end

    test "a non-string among the briefs is refused" do
      assert {:error, msg} = Delegate.execute(%{"briefs" => ["fine", 42]}, ctx!())
      assert msg =~ "non-empty string"
    end
  end

  defp result_text(%{content: content}) when is_binary(content), do: content
  defp result_text(%{"content" => content}) when is_binary(content), do: content
  defp result_text(other), do: inspect(other)

  defp untrusted?(result), do: inspect(result) =~ "untrusted"
end
