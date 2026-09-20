# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.UnitsTest do
  @moduledoc "Slice 020: Result.cap/2 (AC5's unit half), Schema.validate/2, the seam's shape, surface_diff/1."
  use ExUnit.Case, async: true

  alias Trinity.Sessions.Message
  alias Trinity.Tools
  alias Trinity.Tools.{Result, Schema}

  describe "Result.cap/2 (AC5)" do
    test "cuts at the cap on a character boundary, marks it, keeps the original size" do
      long = String.duplicate("é", 100)
      capped = Result.cap(Result.text(long), 51)
      assert capped.truncated?
      assert capped.meta["original_bytes"] == 200
      assert String.starts_with?(capped.content, String.duplicate("é", 25))
      assert String.ends_with?(capped.content, "[truncated: the tool returned more than the cap]")
      assert String.valid?(capped.content)
    end

    test "leaves a result under the cap alone and renders a map as JSON" do
      r = Result.cap(%Result{content: %{"a" => 1}}, 100)
      refute r.truncated?
      assert Result.as_text(r) == ~s({"a":1})
    end
  end

  describe "Schema.validate/2 (AC6's unit half)" do
    @schema %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string"}, "n" => %{"type" => "integer"}},
      "required" => ["text"],
      "additionalProperties" => false
    }

    test "a valid call passes untouched" do
      assert {:ok, %{"text" => "hi", "n" => 2}} =
               Schema.validate(@schema, %{"text" => "hi", "n" => 2})
    end

    test "a missing required key and a wrong type are refused by name, and nothing is repaired" do
      assert {:error, reasons} = Schema.validate(@schema, %{"n" => "x"})
      assert Enum.any?(reasons, &(&1 =~ "text" and &1 =~ "required"))
      assert Enum.any?(reasons, &(&1 =~ "#/n" and &1 =~ "integer"))
      assert {:error, [_ | _]} = Schema.validate(@schema, %{"text" => "hi", "extra" => 1})
      assert {:error, [_ | _]} = Schema.validate(@schema, "not an object")
    end
  end

  test "the runner implements the seam's two functions with its arities" do
    # async: the module may not be loaded yet when this runs first.
    Code.ensure_loaded!(Tools.Runner)
    assert function_exported?(Tools.Runner, :run, 2)
    assert function_exported?(Tools.Runner, :run_all, 2)
    assert Trinity.Sessions.ToolRunner.impl() == Tools.Runner
  end

  describe "surface_diff/1" do
    defp assistant(seq, surface, calls),
      do: %Message{
        role: "assistant",
        seq: seq,
        parts: %{"tool_calls" => calls},
        provider_meta: %{"tool_surface" => surface}
      }

    defp tool(id, digest),
      do: %Message{role: "tool", tool_call_id: id, parts: %{"tool_definition_digest" => digest}}

    test "a call to an undeclared name is a finding; a declared one with the same digest is not" do
      history = [
        assistant(2, %{"echo" => "d1"}, [
          %{"id" => "c1", "name" => "echo"},
          %{"id" => "c2", "name" => "get_weather"}
        ]),
        tool("c1", "d1"),
        tool("c2", nil)
      ]

      assert Tools.surface_diff(history) == [%{seq: 2, name: "get_weather", reason: :undeclared}]
    end

    test "a changed definition is a finding, and a turn with no surface is skipped" do
      history = [
        assistant(2, %{"echo" => "d1"}, [%{"id" => "c1", "name" => "echo"}]),
        tool("c1", "d2"),
        %Message{
          role: "assistant",
          seq: 4,
          parts: %{"tool_calls" => [%{"id" => "c3", "name" => "x"}]},
          provider_meta: %{}
        }
      ]

      assert Tools.surface_diff(history) == [%{seq: 2, name: "echo", reason: :definition_changed}]
    end
  end
end
