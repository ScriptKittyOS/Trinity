# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Gate 3, the digest pin (slice 134, AC7): replacing the blob behind the tag changes the
# /api/tags digest, and a running Trinity goes OFF with :model_digest_changed.
#
#   XDG_DATA_HOME=<dir> MIX_ENV=dev mix run --no-start scripts/tier3/digest_pin.exs \
#     --record <import.json> --swap-gguf <another .gguf> [--interval-ms 2000] [--num-ctx 2048]
#
# A real boot: its own databases under XDG_DATA_HOME, migrated, the application started with the
# Tier 3 embedder configured from the import record, so `Trinity.Memory.Supervisor` starts the
# watcher the way a deployment does. The store is pinned to the record's space, a memory written
# and a message stored. Then the script itself replaces the blob behind the tag, as an operator or
# an attacker with access to the service would (/api/blobs and /api/create with the other GGUF,
# same name), and polls the tier's status until it is OFF, printing the time.
Code.require_file("gate_lib.exs", __DIR__)

alias Trinity.Memory.{AlwaysOn, Retriever, Semantic, Space, Spaces}
alias Trinity.Memory.Embedders.Ollama

opts =
  Tier3Gate.args(System.argv(),
    record: :string,
    swap_gguf: :string,
    interval_ms: :integer,
    num_ctx: :integer,
    base_url: :string
  )

record = Tier3Gate.record!(opts[:record])
interval = Keyword.get(opts, :interval_ms, 2000)
data = System.fetch_env!("XDG_DATA_HOME")
File.mkdir_p!(data)

# The node's own databases and no HTTP listener.
Application.put_env(:trinity, Trinity.Repo, Keyword.put(Application.get_env(:trinity, Trinity.Repo), :database, Path.join(data, "gate3.db")))

Application.put_env(
  :trinity,
  Trinity.Repo.Receipts,
  Keyword.put(Application.get_env(:trinity, Trinity.Repo.Receipts), :database, Path.join(data, "gate3_receipts.db"))
)

Application.put_env(:trinity, TrinityWeb.Endpoint, Keyword.put(Application.get_env(:trinity, TrinityWeb.Endpoint, []), :server, false))
Trinity.Release.migrate()
{:ok, _} = Application.ensure_all_started(:req)
o = Tier3Gate.configure!(record, num_ctx: Keyword.get(opts, :num_ctx, 2048), check_interval_ms: interval, base_url: Keyword.get(opts, :base_url, record["ollama"]["base_url"]))
{:ok, _} = Application.ensure_all_started(:trinity)

t0 = System.monotonic_time(:millisecond)
now = fn -> System.monotonic_time(:millisecond) - t0 end
say = fn line -> IO.puts("GATE3 t=#{now.()}ms #{line}") end

wait = fn want, limit_ms ->
  Enum.find_value(0..div(limit_ms, 20), fn _ ->
    if Semantic.status() == want, do: now.(), else: Process.sleep(20) && nil
  end)
end

say.("booted; watcher #{inspect(Process.whereis(Ollama.Watch) |> is_pid())}; status #{inspect(Semantic.status())}")
row = Trinity.Memory.Spaces.pin_if_empty(Ollama.space()) |> elem(1)
say.("pinned the empty store to space #{Space.short(row.id)} (revision = the /api/tags digest #{o[:digest]})")
true = is_integer(wait.(:on, 30_000))
say.("status :on")

{:ok, persona} = Trinity.Sessions.create_persona(%{name: "gate3", soul: "gate", model: nil})
scope = AlwaysOn.persona_scope(persona.id)
{:ok, _} = Semantic.add(%{persona_id: persona.id, scope: scope, key: "dog", body: "The person's dog is called Rex."}, by: "gate3")
{:ok, session} = Trinity.Sessions.create_session(%{persona_id: persona.id})
{:ok, _} = Trinity.Sessions.append_message(session.id, %{role: "user", content: "my sister lives in Boston"})
{:ok, [before]} = Ollama.embed_query(["what is my dog called?"])
say.("memory written; vectors in the space: #{Spaces.count(row.id)}; recall #{inspect(Retriever.relevant(persona.id, nil, "what is my dog called?", touch: false) |> Enum.map(&{&1.kind, &1.found_by}))}")

# Replace the blob behind the tag.
gguf = opts[:swap_gguf]
sha = :crypto.hash(:sha256, File.read!(gguf)) |> Base.encode16(case: :lower)
base = o[:base_url]
# As the import path does: send the blob only when the service does not hold it already.
s1 =
  case Req.head!(base <> "/api/blobs/sha256:" <> sha, retry: false) do
    %{status: 200} -> "already held"
    %{status: 404} -> Req.post!(base <> "/api/blobs/sha256:" <> sha, body: File.stream!(gguf, 1_048_576), retry: false, receive_timeout: 600_000).status
  end

%{status: 200} = Req.post!(base <> "/api/create", json: %{model: o[:model], files: %{Path.basename(gguf) => "sha256:" <> sha}, stream: false}, retry: false, receive_timeout: 600_000)
{:ok, new_digest} = Ollama.served_digest(o)
swapped = now.()
say.("replaced the blob behind #{o[:model]} with #{Path.basename(gguf)} (blob: #{s1}); /api/tags digest now #{new_digest}")

# What the service now answers for the same query, read directly (Trinity is not asked).
{200, %{"embeddings" => [after_v]}} =
  Tier3Gate.embed_raw(base, o[:model], [o[:query_prompt] <> "what is my dog called?"], o[:num_ctx], false)

say.("the service's vector for the same query, before and after the swap: cosine #{Float.round(Tier3Gate.cosine(before, after_v), 6)}")

off = wait.({:off, :model_digest_changed}, 3 * interval + 1000)

if off do
  say.("status #{inspect(Semantic.status())} #{off - swapped} ms after the swap (interval #{interval} ms)")
else
  say.("still #{inspect(Semantic.status())} #{now.() - swapped} ms after the swap (interval #{interval} ms)")
end

say.("search: #{inspect(Semantic.search(persona.id, [scope], "what is my dog called?", 3) |> then(fn {:error, r} -> {:error, r}; {:ok, h} -> {:ok, length(h)} end))}")
say.("recall: #{inspect(Retriever.relevant(persona.id, nil, "sister Boston", touch: false) |> Enum.map(&{&1.kind, &1.found_by}))}")
say.("active space #{Space.short(Spaces.active().id)} (unchanged: #{Spaces.active().id == row.id}); spaces #{length(Spaces.list())}; jobs #{Trinity.Repo.aggregate(Oban.Job, :count)}")
IO.puts("GATE3 VERDICT #{if off && off - swapped <= interval + 1000, do: "PASS", else: "FAIL"}")
System.halt(0)
