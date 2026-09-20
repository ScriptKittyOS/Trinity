# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.LiveTest do
  @moduledoc """
  Slice 011 AC2, AC3, AC6: the req_llm adapter against real providers. Opt-in:

      set -a; . ./.env; set +a; TRINITY_LIVE=1 mix test --only live

  Reads the registry the way dev and prod do (config/config.exs), not the test fake. Each
  provider's model id is checked against its `GET /models` listing first, so an id that reached
  end of life is a named refusal (410) and not a mysterious failure downstream. Nothing here runs
  in the default suite; keys are never printed.
  """
  use Trinity.DataCase, async: false

  alias Trinity.LLM
  alias Trinity.LLM.{Event, Request}

  @moduletag :live
  @moduletag timeout: 180_000

  @chat_models ["openrouter:ling", "nvidia:nemotron"]

  setup_all do
    if System.get_env("TRINITY_LIVE") != "1",
      do: raise("TRINITY_LIVE=1 is required for the live suite")

    original = Application.get_env(:trinity, :llm)
    Application.put_env(:trinity, :llm, live_registry())
    on_exit(fn -> Application.put_env(:trinity, :llm, original) end)
    :ok
  end

  # The dev/prod registry (config/llm.exs), read now so the environment loaded from .env is
  # what it sees.
  defp live_registry, do: Config.Reader.read!("config/llm.exs")[:trinity][:llm]

  defp preflight(entry) do
    ["openai", model] =
      entry.model
      |> String.split(":", parts: 2)
      |> then(fn [p, m] -> [if(p == "openrouter", do: "openai", else: p), m] end)

    base = Map.get(entry, :base_url, "https://openrouter.ai/api/v1")
    {:ok, key} = Trinity.Config.secret(entry.api_key_env)
    %{status: 200, body: %{"data" => data}} = Req.get!(base <> "/models", auth: {:bearer, key})
    ids = Enum.map(data, & &1["id"])

    assert model in ids,
           "#{entry.id}: model #{model} is not on #{base}/models (#{length(ids)} listed); it may have reached end of life"
  end

  for id <- @chat_models do
    describe "#{id}" do
      @tag model: id
      test "preflight: the configured model is on the provider's list", %{model: id} do
        {:ok, entry} = LLM.Registry.lookup(id)
        preflight(entry)
      end

      @tag model: id
      test "a streamed completion yields text deltas, usage and done", %{model: id} do
        request =
          Request.new!(%{
            model: id,
            messages: [%{role: "user", content: "Reply with exactly: ready"}],
            params: %{max_tokens: 64}
          })

        {:ok, agent} = Agent.start_link(fn -> [] end)
        assert {:ok, usage} = LLM.stream(request, [], fn e -> Agent.update(agent, &[e | &1]) end)
        events = agent |> Agent.get(& &1) |> Enum.reverse()
        assert Enum.all?(events, &Event.valid?/1)

        text =
          events |> Enum.filter(&match?({:text_delta, _}, &1)) |> Enum.map_join("", &elem(&1, 1))

        assert text =~ ~r/ready/i, "text was: #{inspect(text)}"
        assert {:usage, _} = Enum.find(events, &match?({:usage, _}, &1))
        assert {:done, _} = List.last(events)
        assert usage.input_tokens > 0 and usage.output_tokens > 0
      end

      @tag model: id
      test "a tool call arrives as start, end, and a done of tool_calls", %{model: id} do
        request =
          Request.new!(%{
            model: id,
            messages: [
              %{role: "user", content: "What is the weather in Paris? Use the get_weather tool."}
            ],
            tools: [
              %{
                name: "get_weather",
                description: "Weather for a city",
                parameters: %{
                  "type" => "object",
                  "properties" => %{"city" => %{"type" => "string"}},
                  "required" => ["city"]
                }
              }
            ],
            params: %{max_tokens: 512}
          })

        {:ok, agent} = Agent.start_link(fn -> [] end)
        assert {:ok, _} = LLM.stream(request, [], fn e -> Agent.update(agent, &[e | &1]) end)
        events = agent |> Agent.get(& &1) |> Enum.reverse()

        assert {:tool_call_start, call_id, "get_weather"} =
                 Enum.find(events, &match?({:tool_call_start, _, _}, &1))

        assert {:tool_call_end, ^call_id, %{"city" => city}} =
                 Enum.find(events, &match?({:tool_call_end, _, _}, &1))

        assert city =~ ~r/paris/i
        assert {:done, :tool_calls} = List.last(events)
      end

      @tag model: id
      test "generate_object returns a map that validates against the schema (AC2)", %{model: id} do
        schema = %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string"},
            "population_millions" => %{"type" => "number"}
          },
          "required" => ["city", "population_millions"]
        }

        request =
          Request.new!(%{
            model: id,
            messages: [
              %{role: "user", content: "Give the city of Paris and its population in millions."}
            ],
            params: %{max_tokens: 256}
          })

        assert {:ok, %{"city" => city, "population_millions" => pop}} =
                 LLM.generate_object(request, schema)

        assert city =~ ~r/paris/i and is_number(pop)
      end
    end
  end

  test "embed returns vectors of the declared dimension against the NVIDIA embedding model (AC3)" do
    {:ok, entry} = LLM.Registry.lookup("nvidia:embed")
    preflight(entry)

    assert {:ok, [v1, v2]} =
             LLM.embed(["the cat sat", "a cat was sitting"], model: "nvidia:embed")

    assert length(v1) == length(v2) and v1 != []
    assert Enum.all?(v1, &is_float/1)
    IO.puts("\nlive embed: dimension #{length(v1)}")
  end

  test "a live call writes one usage_events row with the tokens the provider reported" do
    request =
      Request.new!(%{
        model: "openrouter:ling",
        messages: [%{role: "user", content: "Reply with exactly: ok"}],
        params: %{max_tokens: 16}
      })

    assert {:ok, %{usage: usage}} = LLM.generate(request)
    assert [row] = Repo.all(Trinity.LLM.Usage)
    assert row.model_id == "openrouter:ling" and row.kind == "chat"
    assert row.input_tokens == usage.input_tokens and row.input_tokens > 0
    assert row.cost_usd == 0.0

    IO.puts(
      "\nlive usage row: #{row.input_tokens} in, #{row.output_tokens} out, provider_cost #{inspect(row.provider_meta["provider_cost"])}"
    )
  end
end
