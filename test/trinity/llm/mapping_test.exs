# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Providers.ReqLLM.MappingTest do
  @moduledoc """
  Slice 011: the req_llm adapter's pure half over recorded chunk sequences. The chunk shapes
  are the ones req_llm 1.24.0's default decoder builds (`lib/req_llm/provider/defaults.ex`,
  `decode_openai_tool_call_delta/1`), reproduced here with the library's own constructors so a
  change in the library's shape is a red here before it is a surprise in production.
  """
  use ExUnit.Case, async: true

  alias ReqLLM.StreamChunk, as: C
  alias Trinity.LLM.{Error, Event}
  alias Trinity.LLM.Providers.ReqLLM.Mapping

  defp run(chunks) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    state = Mapping.reduce(chunks, fn e -> Agent.update(agent, &[e | &1]) end)
    events = agent |> Agent.get(& &1) |> Enum.reverse()
    assert Enum.all?(events, &Event.valid?/1), inspect(events)
    {events, state}
  end

  test "text chunks become text deltas; thinking and empty content are dropped" do
    {events, _} = run([C.text("Hel"), C.thinking("hmm"), C.text(""), C.text("lo")])
    assert events == [{:text_delta, "Hel"}, {:text_delta, "lo"}]
  end

  test "a streamed tool call: open with fragments to follow, two fragments, closed by the finish reason" do
    chunks = [
      C.tool_call("get_weather", %{}, %{id: "call_9", index: 0, expects_arg_fragments: true}),
      C.meta(%{tool_call_args: %{index: 0, fragment: ~s({"city":)}}),
      C.meta(%{tool_call_args: %{index: 0, fragment: ~s("Paris"})}}),
      C.meta(%{finish_reason: "tool_calls"})
    ]

    {events, state} = run(chunks)

    assert events == [
             {:tool_call_start, "call_9", "get_weather"},
             {:tool_call_delta, "call_9", ~s({"city":)},
             {:tool_call_delta, "call_9", ~s("Paris"})},
             {:tool_call_end, "call_9", %{"city" => "Paris"}}
           ]

    assert state.finish == :tool_calls
  end

  test "a complete tool call in one chunk opens and closes at once" do
    {events, _} = run([C.tool_call("get_weather", %{"city" => "Paris"}, %{id: "c1", index: 0})])

    assert events == [
             {:tool_call_start, "c1", "get_weather"},
             {:tool_call_end, "c1", %{"city" => "Paris"}}
           ]
  end

  test "two interleaved calls are assembled by index and closed in order" do
    chunks = [
      C.tool_call("a", %{}, %{id: "ca", index: 0, expects_arg_fragments: true}),
      C.tool_call("b", %{}, %{id: "cb", index: 1, expects_arg_fragments: true}),
      C.meta(%{tool_call_args: %{index: 1, fragment: ~s({"y":2})}}),
      C.meta(%{tool_call_args: %{index: 0, fragment: ~s({"x":1})}})
    ]

    {events, _} = run(chunks)

    assert Enum.filter(events, &match?({:tool_call_end, _, _}, &1)) == [
             {:tool_call_end, "ca", %{"x" => 1}},
             {:tool_call_end, "cb", %{"y" => 2}}
           ]
  end

  test "a call without an id gets a stable synthetic one; unparseable fragments close as no arguments" do
    chunks = [
      C.tool_call("t", %{}, %{index: 0, expects_arg_fragments: true}),
      C.meta(%{tool_call_args: %{index: 0, fragment: "{not json"}})
    ]

    {events, _} = run(chunks)

    assert [
             {:tool_call_start, "call_1", "t"},
             {:tool_call_delta, "call_1", _},
             {:tool_call_end, "call_1", %{}}
           ] = events
  end

  test "a fragment for an unknown index is ignored, and a finish of stop is recorded" do
    {events, state} =
      run([
        C.meta(%{tool_call_args: %{index: 7, fragment: "x"}}),
        C.meta(%{finish_reason: "stop"})
      ])

    assert events == []
    assert state.finish == :stop
  end

  test "finish reasons: the closed vocabulary, and :other for anything else, never a new atom" do
    assert Mapping.finish("stop") == :stop
    assert Mapping.finish("length") == :length
    assert Mapping.finish("tool_calls") == :tool_calls
    assert Mapping.finish("content_filter") == :content_filter
    assert Mapping.finish(:max_output_tokens) == :max_output_tokens

    assert Mapping.finish("some_new_provider_reason_#{System.unique_integer([:positive])}") ==
             :other

    assert Mapping.finish(nil) == :stop
  end

  test "usage is normalised to Trinity's keys with the provider's cost kept aside" do
    assert Mapping.normalise_usage(%{input_tokens: 3, output_tokens: nil, total_cost: 0.5}) ==
             %{
               input_tokens: 3,
               output_tokens: 0,
               cached_tokens: 0,
               reasoning_tokens: 0,
               provider_cost: 0.5
             }

    assert Mapping.normalise_usage(nil) == %{}
  end

  test "tool calls from a complete response take both shapes req_llm returns" do
    assert %{id: "1", name: "t", args: %{"a" => 1}} =
             Mapping.tool_call(%{id: "1", name: "t", arguments: %{"a" => 1}})

    assert %{id: "2", name: "u", args: %{}} =
             Mapping.tool_call(%{id: "2", function: %{name: "u", arguments: nil}})
  end

  describe "classify/1" do
    test "an API error with a status classifies by status" do
      assert %Error{transient?: true, status: 429} =
               Mapping.classify(%ReqLLM.Error.API.Request{reason: "rl", status: 429})

      assert %Error{transient?: false, status: 401} =
               Mapping.classify(%ReqLLM.Error.API.Request{reason: "key", status: 401})
    end

    test "a stream error wrapping a 429 with no status of its own is transient (the live-suite defect)" do
      inner = %ReqLLM.Error.API.Request{
        reason: "Provider returned error",
        status: 429,
        retryable: true
      }

      outer = %ReqLLM.Error.API.Stream{reason: "Stream failed", cause: inner}
      assert %Error{transient?: true, status: 429, reason: ^outer} = Mapping.classify(outer)
    end

    test "a stream error whose cause is a timeout is transient" do
      assert %Error{transient?: true} =
               Mapping.classify(%ReqLLM.Error.API.Stream{
                 reason: "Stream failed: :timeout",
                 cause: :timeout
               })
    end

    test "transport errors are transient; an invalid parameter is permanent; a bare term is permanent" do
      assert %Error{transient?: true} =
               Mapping.classify(%Req.TransportError{reason: :econnrefused})

      assert %Error{transient?: false} =
               Mapping.classify(%ReqLLM.Error.Invalid.Parameter{parameter: "x"})

      assert %Error{transient?: false, reason: :whatever} = Mapping.classify(:whatever)
      assert {:error, %Error{}} = Mapping.wrap({:error, :x})
      assert {:ok, 1} = Mapping.wrap({:ok, 1})
    end
  end
end
