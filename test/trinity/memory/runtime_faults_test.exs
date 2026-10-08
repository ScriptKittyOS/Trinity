# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.RuntimeFaultsTest do
  @moduledoc """
  Slice 133, AC6's first half: a runtime fault turns semantic memory OFF with a reason, and
  full-text recall goes on.

  The embedder here is the hosted one, through the real req_llm adapter, at an endpoint the test
  serves itself on the loopback (Bandit on a random port), answering every request `503`. That
  is the whole path an embedding request takes, adapter, retry and classification included,
  with nothing leaving the machine. Its locality is declared `:within_boundary` (D2), so the
  configuration is valid and the fault is a runtime one.

  AC6's second half (a corrupted byte in the weights, and the application still boots) is a boot,
  and is in `test/trinity/embedder_boot_node_test.exs`.
  """
  use Trinity.SessionCase

  alias Trinity.Factory
  alias Trinity.Memory.{AlwaysOn, Embedders, Retriever, Semantic, Spaces}

  defmodule Unavailable do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, counter) do
      Agent.update(counter, &(&1 + 1))
      conn |> put_resp_content_type("application/json") |> send_resp(503, ~s({"error":"down"}))
    end
  end

  setup do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Bandit.start_link(plug: {Unavailable, counter}, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    llm = Application.get_env(:trinity, :llm, [])
    memory = Application.get_env(:trinity, :memory, [])
    System.put_env("TRINITY_TEST_EMBED_KEY", "unused")

    Application.put_env(
      :trinity,
      :llm,
      llm
      |> Keyword.update!(:providers, &Map.put(&1, :req_llm, Trinity.LLM.Providers.ReqLLM))
      |> Keyword.update!(:models, fn models ->
        models ++
          [
            %{
              id: "local:embed",
              provider: :req_llm,
              model: "openai_compatible:e5",
              base_url: "http://127.0.0.1:#{port}/v1",
              api_key_env: "TRINITY_TEST_EMBED_KEY",
              caps: [:embed],
              price: %{input: 0.0, output: 0.0}
            }
          ]
      end)
    )

    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(memory,
        embedder: :hosted,
        hosted_model: "local:embed",
        hosted_dim: 8,
        locality: :within_boundary
      )
    )

    on_exit(fn ->
      Application.put_env(:trinity, :llm, llm)
      Application.put_env(:trinity, :memory, memory)
      System.delete_env("TRINITY_TEST_EMBED_KEY")
      Semantic.clear_fault(:all)
    end)

    persona = Factory.persona!()
    # A store pinned to the hosted embedder's space, as an operator's re-tier would leave it.
    Trinity.SpacesHelper.pin!(Embedders.Hosted.space())
    {:ok, persona: persona, counter: counter}
  end

  test "AC6: an endpoint answering 503 is :endpoint_unreachable, and full-text hits still come back",
       %{persona: persona, counter: counter} do
    past = Factory.session!(%{persona_id: persona.id, title: "Earlier"})
    Factory.message!(past.id, %{role: "user", content: "my sister lives in Boston"})

    # Configuration is valid and nothing has failed yet: the tier is on.
    assert Semantic.status() == :on
    active = Spaces.active().id

    hits = Retriever.relevant(persona.id, nil, "sister Boston", touch: false)

    # The endpoint was asked (and answered 503), the vector leg is empty, the message is found.
    assert Agent.get(counter, & &1) > 0
    assert [%{kind: :message, found_by: [:fts]}] = hits
    assert Semantic.status() == {:off, :endpoint_unreachable}

    assert Semantic.describe(Semantic.status()) ==
             "semantic recall is unavailable: the embedder's endpoint is unreachable"

    # A runtime fault moves nothing: the pointer is where it was and no job was enqueued.
    assert Spaces.active().id == active
    assert Trinity.Repo.aggregate(Oban.Job, :count) == 0

    # The observer stands down while the tier is off.
    assert Trinity.Memory.Observer.run(
             %{session_id: past.id, persona_id: persona.id, model: nil},
             []
           ) == :off

    IO.puts(
      "\nAC6: #{Agent.get(counter, & &1)} requests answered 503; status #{inspect(Semantic.status())}; hits #{inspect(Enum.map(hits, &{&1.kind, &1.found_by}))}"
    )
  end

  test "a write while the endpoint is down is refused with the reason, and stores nothing",
       %{persona: persona} do
    scope = AlwaysOn.persona_scope(persona.id)

    assert {:error, :endpoint_unreachable} =
             Semantic.add(%{persona_id: persona.id, scope: scope, key: "k", body: "a fact"},
               by: "test"
             )

    assert Semantic.entries(persona.id, [scope]) == []
    assert Spaces.count(Spaces.active().id) == 0
  end
end
