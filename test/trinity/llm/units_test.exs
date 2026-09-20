# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.UnitsTest do
  @moduledoc "Slice 011: Request, Event, Registry, Retry, Config.secret and the error classes."
  use ExUnit.Case, async: true

  alias Trinity.Config
  alias Trinity.LLM.{Error, Event, Registry, Request, Retry}

  describe "Request.new/1" do
    test "accepts the four roles and a tool with a name and parameters" do
      assert {:ok, %Request{}} =
               Request.new(%{
                 messages: [
                   %{role: "system", content: "s"},
                   %{role: "user", content: "u"},
                   %{
                     role: "assistant",
                     content: "",
                     tool_calls: [%{id: "1", name: "t", args: %{}}]
                   },
                   %{role: "tool", content: "r", tool_call_id: "1"}
                 ],
                 tools: [%{name: "t", description: "d", parameters: %{"type" => "object"}}]
               })
    end

    test "refuses an unknown role and a tool without parameters, by name" do
      assert {:error, {:invalid_request, {:message, %{role: "oracle"}}}} =
               Request.new(%{messages: [%{role: "oracle", content: "x"}]})

      assert {:error, {:invalid_request, {:tool, %{name: "t"}}}} =
               Request.new(%{tools: [%{name: "t"}]})
    end
  end

  describe "Event.valid?/1" do
    test "the seven shapes and nothing else" do
      for e <- [
            {:text_delta, "x"},
            {:tool_call_start, "1", "t"},
            {:tool_call_delta, "1", "{"},
            {:tool_call_end, "1", %{}},
            {:usage, %{}},
            {:done, :stop},
            {:error, :any}
          ],
          do: assert(Event.valid?(e), inspect(e))

      refute Event.valid?({:text_delta, 1})
      refute Event.valid?({:chunk, "x"})
      refute Event.valid?({:done, "stop"})
    end
  end

  describe "Registry" do
    test "resolves the default and refuses an unknown id" do
      assert {:ok, %{id: "fake:chat", provider: :fake}} = Registry.lookup(nil)

      assert {:ok, Trinity.LLM.Providers.Fake} =
               Registry.lookup("fake:chat")
               |> then(fn {:ok, e} -> Registry.provider_module(e) end)

      assert {:error, {:unknown_model, "x:y"}} = Registry.lookup("x:y")
      assert {:error, {:unknown_provider, :nope}} = Registry.provider_module(%{provider: :nope})
    end
  end

  describe "Retry.run/2" do
    test "backs off exponentially and stops at the attempt count" do
      {:ok, sleeps} = Agent.start_link(fn -> [] end)
      sleep = fn ms -> Agent.update(sleeps, &[ms | &1]) end
      err = {:error, Error.transient(:t)}

      assert {:error, %Error{reason: {:exhausted, 4, :t}}} =
               Retry.run(fn -> err end, attempts: 4, base_ms: 10, sleep: sleep)

      assert Enum.reverse(Agent.get(sleeps, & &1)) == [10, 20, 40]
    end
  end

  describe "Error" do
    test "statuses classify: 408, 425, 429 and 5xx transient; other 4xx permanent" do
      for s <- [408, 425, 429, 500, 502, 503],
          do: assert(Error.from_status(s, :x).transient?, "#{s}")

      for s <- [400, 401, 403, 404, 422], do: refute(Error.from_status(s, :x).transient?, "#{s}")
      assert Exception.message(Error.from_status(429, :rl)) =~ "transient LLM error (HTTP 429)"
    end
  end

  describe "Config.secret/1" do
    test "a missing or empty variable is a named error, never nil" do
      System.delete_env("TRINITY_TEST_SECRET")

      assert {:error, {:missing_secret, "TRINITY_TEST_SECRET"}} =
               Config.secret("TRINITY_TEST_SECRET")

      System.put_env("TRINITY_TEST_SECRET", "")
      assert {:error, {:missing_secret, _}} = Config.secret("TRINITY_TEST_SECRET")
      System.put_env("TRINITY_TEST_SECRET", "v")
      assert {:ok, "v"} = Config.secret("TRINITY_TEST_SECRET")
      System.delete_env("TRINITY_TEST_SECRET")
    end
  end
end
