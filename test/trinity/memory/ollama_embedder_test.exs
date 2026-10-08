# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.OllamaEmbedderTest do
  @moduledoc """
  Slice 134, AC1: the Tier 3 client always sends `truncate:false`, refuses an over-length input
  itself with `{:error, :input_too_long}` and no vector, and catches a service that truncates
  silently through `prompt_eval_count` below its own count.

  The service is `Trinity.FakeOllama` on the loopback, behaving as Ollama 0.40.0 was observed
  to; the client runs its whole path (its tokenizer, Req, the JSON, the status codes).
  """
  use Trinity.DataCase

  alias Trinity.{Factory, FakeOllama, Tier3Helper}
  alias Trinity.Memory.{AlwaysOn, BPE, EmbedderConfig, Retriever, Semantic, Spaces}
  alias Trinity.Memory.Embedders.Ollama

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    memory = Application.get_env(:trinity, :memory, [])
    Ollama.reset()

    on_exit(fn ->
      Application.put_env(:trinity, :memory, memory)
      Ollama.reset()
    end)

    tok = Tier3Helper.write_tokenizer!(dir)
    fake = FakeOllama.start!(Tier3Helper.tokenizer())
    config = Tier3Helper.memory(fake.url, tok)
    Application.put_env(:trinity, :memory, Keyword.merge(memory, config))
    FakeOllama.put_model(fake.agent, "embed-test", config[:ollama][:digest])
    :ok = Ollama.check()
    {:ok, fake: fake, config: config}
  end

  defp count(text), do: BPE.count(Tier3Helper.tokenizer(), text)

  test "every request carries truncate:false and the pinned num_ctx; queries carry the query template",
       %{fake: fake} do
    assert {:ok, [d1, d2]} = Ollama.embed(["hello world", "a second fact"])
    assert {:ok, [q]} = Ollama.embed_query(["what did I say?"])
    assert length(d1) == 8 and length(d2) == 8 and length(q) == 8

    requests = FakeOllama.requests(fake.agent, "/api/embed")
    assert length(requests) == 2

    for {"POST", _, body} <- requests do
      assert body["truncate"] == false
      assert body["options"] == %{"num_ctx" => 64}
      assert body["model"] == "embed-test"
    end

    assert [
             {_, _, %{"input" => ["hello world", "a second fact"]}},
             {_, _, %{"input" => ["Q: what did I say?"]}}
           ] =
             requests
  end

  test "AC1: an input over Trinity's own limit is {:error, :input_too_long}, and nothing is sent",
       %{fake: fake} do
    long = String.duplicate("x", 100)
    assert count(long) > 63

    assert Ollama.embed([long]) == {:error, :input_too_long}
    assert Ollama.embed(["short", long]) == {:error, :input_too_long}
    assert FakeOllama.requests(fake.agent, "/api/embed") == []

    # At the limit exactly, it is sent and answered.
    at_limit = String.duplicate("x", 62)
    assert count(at_limit) == 63
    assert {:ok, [_]} = Ollama.embed([at_limit])

    # The refusal is about that input: the embedder stays available.
    assert Ollama.availability() == :ok
  end

  test "AC1 red: a service that truncates silently is caught through prompt_eval_count",
       %{fake: fake} do
    FakeOllama.set(fake.agent, :mode, {:truncate_silently, 4})
    text = "my sister lives in Boston"
    counted = count(text)
    assert counted > 4 and counted <= 63

    # The service answers 200 with a vector; the client returns no vector.
    assert Ollama.embed([text]) == {:error, :input_too_long}
    assert [{_, _, %{"truncate" => false}}] = FakeOllama.requests(fake.agent, "/api/embed")

    # And the embedder is OFF with the counts, until a restart: a short input that fits the
    # service's cut does not bring it back.
    assert Ollama.availability() == {:off, {:service_truncated, %{counted: counted, served: 4}}}
    assert Ollama.embed(["hi"]) == {:error, {:service_truncated, %{counted: counted, served: 4}}}

    IO.puts(
      "\nAC1: counted #{counted}, the service reported #{4}; availability #{inspect(Ollama.availability())}"
    )
  end

  test "AC1 through the store: the truncating service stores no vector, and full text still answers",
       %{fake: fake} do
    persona = Factory.persona!()
    scope = AlwaysOn.persona_scope(persona.id)
    Trinity.SpacesHelper.pin!(Ollama.space())
    assert Semantic.status() == :on

    past = Factory.session!(%{persona_id: persona.id, title: "Earlier"})
    Factory.message!(past.id, %{role: "user", content: "my sister lives in Boston"})

    FakeOllama.set(fake.agent, :mode, {:truncate_silently, 4})

    assert {:error, :input_too_long} =
             Semantic.add(
               %{
                 persona_id: persona.id,
                 scope: scope,
                 key: "k",
                 body: "my sister lives in Boston"
               },
               by: "test"
             )

    assert Semantic.entries(persona.id, [scope]) == []
    assert Spaces.count(Spaces.active().id) == 0
    assert {:off, {:service_truncated, _}} = Semantic.status()

    hits = Retriever.relevant(persona.id, nil, "sister Boston", touch: false)
    assert [%{kind: :message, found_by: [:fts]}] = hits
  end

  test "an over-length input refused by Trinity is not a fault of the tier", %{fake: _fake} do
    Trinity.SpacesHelper.pin!(Ollama.space())
    assert Semantic.embed([String.duplicate("x", 100)]) == {:error, :input_too_long}
    assert Semantic.status() == :on
  end

  test "the service's own refusal on context length is :input_too_long", %{fake: fake} do
    FakeOllama.set(fake.agent, :mode, {:ctx, 8})
    text = "my sister lives in Boston"
    assert count(text) > 7
    assert Ollama.embed([text]) == {:error, :input_too_long}
    assert Ollama.availability() == :ok
  end

  test "a vector of the wrong width or length is refused", %{fake: fake} do
    FakeOllama.set(fake.agent, :dim, 7)
    assert {:error, {:vector_shape, 7, 8}} = Ollama.embed(["hello"])
    FakeOllama.set(fake.agent, :dim, 8)
    FakeOllama.set(fake.agent, :norm, 0.9)
    assert {:error, {:vector_shape, 8, 8}} = Ollama.embed(["hello"])
  end

  test "an endpoint answering 503 is :endpoint_unreachable, and the store records it", %{
    fake: fake
  } do
    Trinity.SpacesHelper.pin!(Ollama.space())
    FakeOllama.set(fake.agent, :mode, :down)
    assert Ollama.embed(["hello"]) == {:error, :endpoint_unreachable}
    assert {:error, :endpoint_unreachable} = Semantic.embed(["hello"])
    assert Semantic.status() == {:off, :endpoint_unreachable}
  end

  test "a search embeds its query with the query template; a memory with the document template",
       %{fake: fake} do
    persona = Factory.persona!()
    scope = AlwaysOn.persona_scope(persona.id)
    Trinity.SpacesHelper.pin!(Ollama.space())

    attrs = %{persona_id: persona.id, scope: scope, key: "k", body: "the dog is Rex"}
    assert {:ok, _} = Semantic.add(attrs, by: "t")

    assert {:ok, _} = Semantic.search(persona.id, [scope], "dog name", 5)

    inputs = for {_, _, %{"input" => i}} <- FakeOllama.requests(fake.agent, "/api/embed"), do: i
    assert ["the dog is Rex"] in inputs
    assert ["Q: dog name"] in inputs
  end

  describe "configuration faults (refuse a regulated boot, OFF under :default)" do
    test "max_input_tokens not below num_ctx", %{config: config} do
      bad = put_in(config, [:ollama, :max_input_tokens], 64)

      assert EmbedderConfig.check(:default, bad, [], nil) ==
               {:error, {:ollama_config, {:max_input_not_below_num_ctx, 64, 64}}}
    end

    test "a pin that is not a SHA-256, and a missing pin", %{config: config} do
      assert {:error, {:ollama_config, {:not_a_sha256, :digest}}} =
               EmbedderConfig.check(
                 :default,
                 put_in(config, [:ollama, :digest], "latest"),
                 [],
                 nil
               )

      missing = Keyword.update!(config, :ollama, &Keyword.delete(&1, :digest))

      assert {:error, {:ollama_config, {:option, :digest, _}}} =
               EmbedderConfig.check(:default, missing, [], nil)
    end

    test "the endpoint's locality must be declared, and allow-listed under :regulated", %{
      config: config
    } do
      undeclared = Keyword.delete(config, :locality)

      assert {:error, {:embedder_locality_undeclared, :ollama, _}} =
               EmbedderConfig.check(:default, undeclared, [], nil)

      assert {:error, {:not_allow_listed, :ollama, "http://127.0.0.1"}} =
               EmbedderConfig.check(:regulated, config, [], "https://elsewhere.internal")

      assert :ok = EmbedderConfig.check(:regulated, config, [], "http://127.0.0.1")
    end

    test "under :default a fault is OFF with {:config, reason}", %{config: config} do
      memory = Application.get_env(:trinity, :memory)
      Application.put_env(:trinity, :memory, put_in(memory, [:ollama, :max_input_tokens], 99))

      assert {:off, {:config, {:ollama_config, {:max_input_not_below_num_ctx, 99, 64}}}} =
               Semantic.status()

      _ = config
    end
  end

  test "a tokenizer file that is not the pinned one is OFF with :tokenizer_digest_mismatch",
       %{config: config, tmp_dir: dir} do
    path = Path.join(dir, "other.bpe.json")
    File.write!(path, File.read!(config[:ollama][:tokenizer_path]) <> " ")
    memory = Application.get_env(:trinity, :memory)
    Application.put_env(:trinity, :memory, put_in(memory, [:ollama, :tokenizer_path], path))
    assert Ollama.availability() == {:off, :tokenizer_digest_mismatch}

    Application.put_env(
      :trinity,
      :memory,
      put_in(memory, [:ollama, :tokenizer_path], path <> ".absent")
    )

    assert Ollama.availability() == {:off, :tokenizer_missing}
  end
end
