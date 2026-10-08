# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.OllamaDigestTest do
  @moduledoc """
  Slice 134, AC2: changing the fake `/api/tags` digest leaves the store OFF with
  `:model_digest_changed` within one check interval, with FTS5 continuing and no other space
  selected.

  The watcher (`Embedders.Ollama.Watch`) runs as the application would run it, under the test's
  supervisor, with a short interval; the service is `Trinity.FakeOllama` on the loopback.
  """
  use Trinity.DataCase

  alias Trinity.{Factory, FakeOllama, Tier3Helper}
  alias Trinity.Memory.{AlwaysOn, Retriever, Semantic, SpaceRow, Spaces}
  alias Trinity.Memory.Embedders.Ollama

  @moduletag :tmp_dir
  @interval 200

  setup %{tmp_dir: dir} do
    memory = Application.get_env(:trinity, :memory, [])
    Ollama.reset()

    on_exit(fn ->
      Application.put_env(:trinity, :memory, memory)
      Ollama.reset()
    end)

    tok = Tier3Helper.write_tokenizer!(dir)
    fake = FakeOllama.start!(Tier3Helper.tokenizer())
    config = Tier3Helper.memory(fake.url, tok, check_interval_ms: @interval)
    Application.put_env(:trinity, :memory, Keyword.merge(memory, config))
    FakeOllama.put_model(fake.agent, "embed-test", config[:ollama][:digest])
    {:ok, fake: fake, pinned: config[:ollama][:digest]}
  end

  # Polls every 5 ms until `status/0` answers `want`, up to `limit` ms: the elapsed ms, or nil.
  defp until_status(want, limit) do
    t0 = System.monotonic_time(:millisecond)

    Enum.find_value(0..div(limit, 5), fn _ ->
      if Semantic.status() == want,
        do: System.monotonic_time(:millisecond) - t0,
        else: Process.sleep(5) && nil
    end)
  end

  test "AC2: a changed /api/tags digest is OFF with :model_digest_changed within one interval; FTS goes on; no other space",
       %{fake: fake, pinned: pinned} do
    persona = Factory.persona!()
    scope = AlwaysOn.persona_scope(persona.id)
    row = Trinity.SpacesHelper.pin!(Ollama.space())

    # Before the first check has answered, nothing is served.
    assert Semantic.status() == {:off, :digest_unchecked}
    start_supervised!(Ollama.Watch)
    assert until_status(:on, 2_000), "the tier never came on after the first check"

    {:ok, _} =
      Semantic.add(%{persona_id: persona.id, scope: scope, key: "k", body: "the dog is Rex"},
        by: "t"
      )

    past = Factory.session!(%{persona_id: persona.id, title: "Earlier"})
    Factory.message!(past.id, %{role: "user", content: "my sister lives in Boston"})
    spaces_before = Repo.aggregate(SpaceRow, :count)

    # A new blob behind the tag.
    FakeOllama.set_digest(fake.agent, "embed-test", String.duplicate("e", 64))
    elapsed = until_status({:off, :model_digest_changed}, 5 * @interval)
    assert elapsed, "still #{inspect(Semantic.status())} after #{5 * @interval} ms"
    assert elapsed <= @interval + 100, "OFF after #{elapsed} ms, interval #{@interval} ms"

    # Full-text recall goes on; the vector leg stands down.
    hits = Retriever.relevant(persona.id, nil, "sister Boston", touch: false)
    assert [%{kind: :message, found_by: [:fts]}] = hits

    # Nothing moved: the same active space, no space registered, no job enqueued, the vector kept.
    assert Spaces.active().id == row.id
    assert Repo.aggregate(SpaceRow, :count) == spaces_before
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Spaces.count(row.id) == 1
    assert Ollama.space() |> Trinity.Memory.Space.id() == row.id

    IO.puts(
      "\nAC2: OFF #{elapsed} ms after the digest changed (interval #{@interval} ms); status #{inspect(Semantic.status())}; " <>
        "hits #{inspect(Enum.map(hits, &{&1.kind, &1.found_by}))}; active #{Trinity.Memory.Space.short(Spaces.active().id)} unchanged"
    )

    # The pinned digest again (the same weights) is the same space: on again at the next check.
    FakeOllama.set_digest(fake.agent, "embed-test", pinned)
    assert until_status(:on, 5 * @interval)
  end

  test "another runtime version is OFF with :runtime_version_changed", %{fake: fake} do
    Trinity.SpacesHelper.pin!(Ollama.space())
    start_supervised!(Ollama.Watch)
    assert until_status(:on, 2_000)
    FakeOllama.set_version(fake.agent, "0.40.1")
    assert until_status({:off, :runtime_version_changed}, 5 * @interval)
  end

  test "a model the service no longer lists is OFF with :model_not_served", %{fake: fake} do
    Trinity.SpacesHelper.pin!(Ollama.space())
    start_supervised!(Ollama.Watch)
    assert until_status(:on, 2_000)
    FakeOllama.remove_model(fake.agent, "embed-test")
    assert until_status({:off, :model_not_served}, 5 * @interval)
  end

  test "a service that stops answering is OFF with :endpoint_unreachable", %{fake: fake} do
    Trinity.SpacesHelper.pin!(Ollama.space())
    start_supervised!(Ollama.Watch)
    assert until_status(:on, 2_000)
    FakeOllama.set(fake.agent, :mode, :down)
    assert until_status({:off, :endpoint_unreachable}, 5 * @interval)
  end

  test "check_now/0 answers the current comparison", %{fake: fake} do
    start_supervised!(Ollama.Watch)
    assert Ollama.Watch.check_now() == :ok
    FakeOllama.set_digest(fake.agent, "embed-test", String.duplicate("e", 64))
    assert Ollama.Watch.check_now() == {:off, :model_digest_changed}
  end

  test "the describe line names the reason" do
    assert Semantic.describe({:off, :model_digest_changed}) =~
             "model digest is not the pinned one"
  end
end
