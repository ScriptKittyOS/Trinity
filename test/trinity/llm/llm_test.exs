# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLMTest do
  @moduledoc "Slice 011 AC1, AC3, AC4, AC5, AC7 through the scripted fake and the Mox mock."
  use Trinity.DataCase, async: false
  import Mox

  alias Trinity.LLM
  alias Trinity.LLM.{Error, Event, Providers.Fake, Request, Usage}

  setup :verify_on_exit!

  setup do
    Process.delete({Fake, :script})
    Process.delete({Fake, :fail})
    Process.delete({Fake, :calls})
    :ok
  end

  defp request(attrs \\ %{}) do
    Request.new!(Map.merge(%{messages: [%{role: "user", content: "hi"}]}, attrs))
  end

  defp collect(request, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    result = LLM.stream(request, opts, fn event -> Agent.update(agent, &[event | &1]) end)
    events = agent |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(agent)
    {result, events}
  end

  describe "stream/3 (AC1)" do
    test "emits the full sequence: text deltas, tool call start, deltas, end, usage, done" do
      {{:ok, usage}, events} = collect(request())

      assert Enum.all?(events, &Event.valid?/1)

      assert [
               {:text_delta, "Hello, "},
               {:text_delta, "world."},
               {:tool_call_start, "call_1", "get_weather"},
               {:tool_call_delta, "call_1", _},
               {:tool_call_delta, "call_1", _},
               {:tool_call_end, "call_1", %{"city" => "Paris"}},
               {:usage, %{input_tokens: 10, output_tokens: 5}},
               {:done, :tool_calls}
             ] = events

      assert usage == %{input_tokens: 10, output_tokens: 5}
    end

    test "stream_to/3 delivers the same events as messages and then llm_done" do
      {:ok, ref} = LLM.stream_to(request(), [], self())
      assert_receive {:llm_event, ^ref, {:text_delta, "Hello, "}}, 1_000
      assert_receive {:llm_event, ^ref, {:done, :tool_calls}}, 1_000
      assert_receive {:llm_done, ^ref, {:ok, %{input_tokens: 10}}}, 1_000
    end
  end

  describe "embed/2 (AC3)" do
    test "returns one vector per text of the declared dimension" do
      {:ok, [{:embed_dim, dim}]} =
        then(LLM.capabilities("fake:embed"), fn {:ok, caps} ->
          {:ok, Enum.filter(caps, &match?({:embed_dim, _}, &1))}
        end)

      assert {:ok, vectors} = LLM.embed(["a", "b", "c"], model: "fake:embed")
      assert length(vectors) == 3
      assert Enum.all?(vectors, &(length(&1) == dim))
    end
  end

  describe "retry (AC4)" do
    test "a transient error is retried and then succeeds" do
      Fake.fail(2, Error.from_status(429, :rate_limited))
      assert {:ok, %{text: "Hello, world."}} = LLM.generate(request())
      assert Fake.calls() == 3
    end

    test "attempts exhausted returns the error, named as exhausted" do
      Fake.fail(10, Error.from_status(503, :down))

      assert {:error, %Error{transient?: true, reason: {:exhausted, 3, :down}}} =
               LLM.generate(request())

      assert Fake.calls() == 3
    end

    test "a permanent error returns at once with one attempt" do
      Fake.fail(10, Error.from_status(401, :bad_key))
      assert {:error, %Error{transient?: false, status: 401}} = LLM.generate(request())
      assert Fake.calls() == 1
    end

    test "no usage row is written for a failed call" do
      Fake.fail(10, Error.from_status(401, :bad_key))
      {:error, _} = LLM.generate(request())
      assert Repo.aggregate(Usage, :count) == 0
    end
  end

  describe "usage_events (AC5)" do
    test "one row per completed call, cost from the registry price" do
      {{:ok, _}, _} = collect(request())
      assert [row] = Repo.all(Usage)
      assert row.model_id == "fake:chat"
      assert row.provider == "fake"
      assert row.kind == "chat"
      assert {row.input_tokens, row.output_tokens} == {10, 5}
      # 10 input tokens at $1.00 per million plus 5 output tokens at $2.00 per million.
      assert row.cost_usd == 0.00002
      assert row.provider_meta == %{"provider_cost" => nil}
    end

    test "the session id is recorded when given" do
      session = Trinity.Factory.session!()
      {{:ok, _}, _} = collect(request(), session_id: session.id)
      assert [%{session_id: sid}] = Repo.all(Usage)
      assert sid == session.id
    end

    test "embed and object calls record their own kinds" do
      {:ok, _} = LLM.embed(["x"], model: "fake:embed")

      {:ok, _} =
        LLM.generate_object(request(), %{"properties" => %{"n" => %{"type" => "integer"}}})

      assert Repo.all(Usage) |> Enum.map(& &1.kind) |> Enum.sort() == ["embed", "object"]
    end
  end

  describe "default_model (AC7)" do
    test "switching default_model in config changes the provider used, with no code change" do
      {{:ok, _}, events} = collect(request())
      assert {:text_delta, "Hello, "} in events

      original = Application.get_env(:trinity, :llm)
      on_exit(fn -> Application.put_env(:trinity, :llm, original) end)
      Application.put_env(:trinity, :llm, Keyword.put(original, :default_model, "mock:chat"))

      expect(Trinity.LLM.ProviderMock, :stream, fn _request, opts, emit ->
        assert opts[:model] == "chat"
        emit.({:text_delta, "from the mock"})
        emit.({:done, :stop})
        {:ok, %{input_tokens: 1, output_tokens: 1}}
      end)

      {{:ok, _}, events} = collect(request())
      assert events == [{:text_delta, "from the mock"}, {:done, :stop}]
      assert LLM.default_model() == "mock:chat"
    end

    test "an unknown model id is refused by name" do
      assert {:error, {:unknown_model, "nope:x"}} = LLM.generate(request(%{model: "nope:x"}))
    end
  end

  describe "generate_object/3" do
    test "returns a map shaped by the schema (fake)" do
      schema = %{
        "type" => "object",
        "properties" => %{"age" => %{"type" => "integer"}, "name" => %{"type" => "string"}}
      }

      assert {:ok, %{"age" => 42, "name" => "fake"}} = LLM.generate_object(request(), schema)
    end
  end
end
