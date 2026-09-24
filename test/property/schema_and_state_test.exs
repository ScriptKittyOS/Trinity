# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Property.SchemaAndStateTest do
  @moduledoc """
  Slice 004 AC2 and AC3.

  The validator is the first thing a tool call meets, and everything after it assumes the arguments
  are shaped. What it must never do is crash: a crash there is an unhandled exit on the path a model
  can reach with arbitrary JSON, which turns a bad argument into a denial of service rather than a
  refusal.

  The state modifier already has an exhaustive test in slice 028 over the four states. This property
  complements it rather than replacing it: it generates the decisions and the sequences, so it still
  holds if someone adds a fifth state and forgets the exhaustive one.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trinity.Permissions.Policy.State
  alias Trinity.Tools.Schema

  @strictness %{allow: 0, ask: 1, deny: 2}

  defp json_scalar do
    one_of([string(:printable, max_length: 15), integer(), float(), boolean(), constant(nil)])
  end

  defp json_value(0), do: json_scalar()

  defp json_value(depth) do
    one_of([
      json_scalar(),
      list_of(json_value(depth - 1), max_length: 3),
      map_of(string(:alphanumeric, min_length: 1, max_length: 6), json_value(depth - 1),
        max_length: 3
      )
    ])
  end

  describe "the argument validator" do
    property "answers ok or a named refusal for any generated arguments, and never raises" do
      schema = %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}, "count" => %{"type" => "integer"}},
        "required" => ["path"]
      }

      check all(
              args <-
                map_of(string(:alphanumeric, min_length: 1, max_length: 6), json_value(2),
                  max_length: 5
                )
            ) do
        case Schema.validate(schema, args) do
          {:ok, validated} -> assert is_map(validated)
          {:error, reasons} -> assert [_ | _] = reasons
        end
      end
    end

    property "a non-object is refused by name rather than raising" do
      check all(
              not_an_object <-
                one_of([
                  string(:printable),
                  integer(),
                  list_of(integer(), max_length: 3),
                  boolean()
                ])
            ) do
        assert {:error, [reason]} = Schema.validate(%{"type" => "object"}, not_an_object)
        assert reason =~ "must be an object"
      end
    end

    property "a generated schema is either usable or reported unusable, never a crash" do
      check all(
              schema <-
                map_of(string(:alphanumeric, min_length: 1, max_length: 6), json_value(2),
                  max_length: 4
                )
            ) do
        assert is_boolean(Schema.valid_schema?(schema))
      end
    end
  end

  describe "the tighten-only state modifier" do
    property "no generated sequence of states ever produces a weaker decision" do
      check all(
              decision <- member_of([:allow, :ask, :deny]),
              states <- list_of(member_of(State.kinds()), max_length: 8)
            ) do
        {result, applied} = State.tighten(decision, states)

        assert @strictness[result] >= @strictness[decision]
        assert Enum.all?(applied, &(&1 in states))
        if result == decision, do: assert(applied == [])
      end
    end

    property "order does not matter to the result" do
      check all(
              decision <- member_of([:allow, :ask, :deny]),
              states <- list_of(member_of(State.kinds()), max_length: 6)
            ) do
        {a, _} = State.tighten(decision, states)
        {b, _} = State.tighten(decision, Enum.shuffle(states))
        assert a == b
      end
    end

    property "repeating a state changes nothing, so a caller cannot tighten by shouting" do
      check all(
              decision <- member_of([:allow, :ask, :deny]),
              states <- list_of(member_of(State.kinds()), min_length: 1, max_length: 4),
              n <- integer(2..4)
            ) do
        {once, _} = State.tighten(decision, states)
        {repeated, _} = State.tighten(decision, List.duplicate(states, n) |> List.flatten())
        assert once == repeated
      end
    end
  end
end
