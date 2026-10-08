# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.FakeOllama do
  @moduledoc """
  Test-only: the parts of Ollama's HTTP API the Tier 3 client and its import path use (slice
  134), served on the loopback by Bandit, so the whole client path (Req, the JSON, the status
  codes) runs with nothing leaving the machine.

  It behaves as Ollama 0.40.0 was observed to (slice 134 NOTES, "Facts gathered"): `/api/embed`
  counts each input's tokens with the tokenizer it is given, accepts at most `num_ctx - 1`, and
  with `truncate: false` answers an over-length input `400 {"error": "the input length exceeds
  the context length"}`; `prompt_eval_count` is the batch's sum; `/api/tags` lists each model
  with a 64-hex digest and the `:latest` tag added. A test changes its behaviour through the
  Agent:

    * `mode: {:truncate_silently, n}`: every input is cut to `n` tokens and answered 200,
      whatever `truncate` says (the service AC1's red is about);
    * `mode: {:ctx, n}`: the service enforces its own context of `n`, not the request's;
    * `mode: :down`: every request is answered 503;
    * `set_digest/3`, `set_version/2`, `remove_model/2`: what `/api/tags` and `/api/version` say;
    * `dim:` and `norm:`: the vectors' width and length.

  Every request is recorded (`requests/1`).
  """
  import Plug.Conn

  alias Trinity.Memory.BPE

  @doc "Starts the Agent and the server under the test's supervisor; `%{url: _, agent: _}`."
  @spec start!(BPE.t(), keyword()) :: %{url: String.t(), agent: pid()}
  def start!(tokenizer, opts \\ []) do
    state = %{
      tokenizer: tokenizer,
      models: %{},
      version: Keyword.get(opts, :version, "0.40.0"),
      mode: :honest,
      dim: Keyword.get(opts, :dim, 8),
      norm: 1.0,
      requests: [],
      blobs: %{},
      show_blob: nil,
      create_digest: nil
    }

    agent = ExUnit.Callbacks.start_supervised!({Agent, fn -> state end}, id: make_ref())

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, agent}, ip: :loopback, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", agent: agent}
  end

  @doc "Registers a model as `/api/create` would, with a given digest."
  @spec put_model(pid(), String.t(), String.t(), String.t()) :: :ok
  def put_model(agent, name, digest, blob \\ String.duplicate("b", 64)) do
    Agent.update(agent, &put_in(&1, [:models, full(name)], %{digest: digest, blob: blob}))
  end

  @doc "Changes the digest `/api/tags` lists for a model (a new blob behind the tag)."
  @spec set_digest(pid(), String.t(), String.t()) :: :ok
  def set_digest(agent, name, digest),
    do: Agent.update(agent, &put_in(&1, [:models, full(name), :digest], digest))

  @doc "Removes a model from `/api/tags`."
  @spec remove_model(pid(), String.t()) :: :ok
  def remove_model(agent, name),
    do: Agent.update(agent, &update_in(&1, [:models], fn m -> Map.delete(m, full(name)) end))

  @doc "Sets what `/api/version` answers."
  @spec set_version(pid(), String.t()) :: :ok
  def set_version(agent, v), do: Agent.update(agent, &Map.put(&1, :version, v))

  @doc "Sets a field of the state (`mode`, `dim`, `norm`, `show_blob`, `create_digest`)."
  @spec set(pid(), atom(), term()) :: :ok
  def set(agent, key, value), do: Agent.update(agent, &Map.put(&1, key, value))

  @doc "The recorded requests, oldest first, as `{method, path, decoded body}`."
  @spec requests(pid(), String.t() | nil) :: [{String.t(), String.t(), term()}]
  def requests(agent, path \\ nil) do
    agent
    |> Agent.get(& &1.requests)
    |> Enum.reverse()
    |> Enum.filter(fn {_, p, _} -> path == nil or p == path end)
  end

  @doc "The blobs received, by SHA-256."
  @spec blobs(pid()) :: %{String.t() => binary()}
  def blobs(agent), do: Agent.get(agent, & &1.blobs)

  defp full(name), do: if(String.contains?(name, ":"), do: name, else: name <> ":latest")

  ## The plug

  def init(agent), do: agent

  def call(conn, agent) do
    {:ok, raw, conn} = read_all(conn, "")
    body = if raw != "" and json?(conn), do: Jason.decode!(raw), else: raw
    path = "/" <> Enum.join(conn.path_info, "/")
    Agent.update(agent, &Map.update!(&1, :requests, fn r -> [{conn.method, path, body} | r] end))
    state = Agent.get(agent, & &1)

    if state.mode == :down,
      do: reply(conn, 503, %{"error" => "down"}),
      else: route(conn, conn.method, path, body, state, agent)
  end

  defp read_all(conn, acc) do
    case read_body(conn, length: 64_000_000) do
      {:ok, data, conn} -> {:ok, acc <> data, conn}
      {:more, data, conn} -> read_all(conn, acc <> data)
    end
  end

  defp json?(conn), do: not String.starts_with?(conn.request_path, "/api/blobs")

  defp route(conn, "GET", "/api/version", _body, state, _agent),
    do: reply(conn, 200, %{"version" => state.version})

  defp route(conn, "GET", "/api/tags", _body, state, _agent) do
    models =
      for {name, m} <- Enum.sort(state.models),
          do: %{"name" => name, "model" => name, "digest" => m.digest, "size" => 1}

    reply(conn, 200, %{"models" => models})
  end

  defp route(conn, "POST", "/api/embed", body, state, _agent), do: embed(conn, body, state)

  defp route(conn, "HEAD", "/api/blobs/sha256:" <> sha, _body, state, _agent),
    do:
      if(Map.has_key?(state.blobs, sha),
        do: send_resp(conn, 200, ""),
        else: send_resp(conn, 404, "")
      )

  defp route(conn, "POST", "/api/blobs/sha256:" <> sha, raw, _state, agent) do
    if Base.encode16(:crypto.hash(:sha256, raw), case: :lower) == sha do
      Agent.update(agent, &put_in(&1, [:blobs, sha], raw))
      send_resp(conn, 201, "")
    else
      reply(conn, 400, %{"error" => "digest mismatch"})
    end
  end

  defp route(conn, "POST", "/api/create", %{"model" => name, "files" => files}, state, agent) do
    [{_file, "sha256:" <> sha}] = Map.to_list(files)

    if Map.has_key?(state.blobs, sha) do
      digest =
        state.create_digest ||
          Base.encode16(:crypto.hash(:sha256, full(name) <> sha), case: :lower)

      put_model(agent, name, digest, sha)
      reply(conn, 200, %{"status" => "success"})
    else
      reply(conn, 400, %{"error" => "blob not found"})
    end
  end

  defp route(conn, "POST", "/api/show", %{"model" => name}, state, _agent) do
    case state.models[full(name)] do
      nil ->
        reply(conn, 404, %{"error" => "model not found"})

      m ->
        blob = state.show_blob || m.blob

        reply(conn, 200, %{
          "modelfile" => "FROM /models/blobs/sha256-#{blob}\nTEMPLATE {{ .Prompt }}\n"
        })
    end
  end

  defp route(conn, _method, _path, _body, _state, _agent),
    do: reply(conn, 404, %{"error" => "not found"})

  defp embed(conn, %{"model" => name, "input" => inputs} = body, state) do
    inputs = List.wrap(inputs)
    ctx = context(state.mode, get_in(body, ["options", "num_ctx"]) || 4096)
    counts = Enum.map(inputs, &BPE.count(state.tokenizer, &1))

    cond do
      not Map.has_key?(state.models, full(name)) ->
        reply(conn, 404, %{"error" => "model \"#{name}\" not found"})

      match?({:truncate_silently, _}, state.mode) ->
        {:truncate_silently, n} = state.mode
        answer(conn, name, inputs, Enum.map(counts, &min(&1, n)), state)

      body["truncate"] == false and Enum.any?(counts, &(&1 > ctx - 1)) ->
        reply(conn, 400, %{"error" => "the input length exceeds the context length"})

      true ->
        answer(conn, name, inputs, Enum.map(counts, &min(&1, ctx - 1)), state)
    end
  end

  defp context({:ctx, n}, _requested), do: n
  defp context(_mode, requested), do: requested

  defp answer(conn, name, inputs, served, state) do
    reply(conn, 200, %{
      "model" => name,
      "embeddings" => Enum.map(inputs, &vector(&1, state.dim, state.norm)),
      "prompt_eval_count" => Enum.sum(served)
    })
  end

  @doc "The fake's deterministic vector for a text: `dim` components from its SHA-512, of length `norm`."
  @spec vector(String.t(), pos_integer(), float()) :: [float()]
  def vector(text, dim, norm \\ 1.0) do
    bytes =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&:crypto.hash(:sha512, [text, <<&1::32>>]))
      |> Enum.take(div(dim, 64) + 1)
      |> IO.iodata_to_binary()

    raw = for <<b::signed-8 <- binary_part(bytes, 0, dim)>>, do: b / 1.0
    len = :math.sqrt(Enum.reduce(raw, 0.0, &(&1 * &1 + &2)))
    Enum.map(raw, &(&1 / len * norm))
  end

  defp reply(conn, status, map) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(map))
  end
end
