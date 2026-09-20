# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Providers.Fake do
  @moduledoc """
  A scripted provider. Slice 011, extended at 012 and 013. The default script streams two
  text deltas, one tool call in three chunks, usage and done. A test sets a script (`script/1`)
  or a sequence of scripts consumed one per call with the last repeating (`scripts/1`), or asks
  for `n` failures before success (`fail/2`). State is global (a persistent term), because a
  session's Task is not on the test process's `$callers` chain; tests using this provider are
  not `async: true`, and `clear/0` runs in their setup.

  Since slice 013 it lives in `lib/` rather than `test/support`, because development runs it
  too: `TRINITY_FAKE_PROVIDER=1` puts it in the dev registry (config/runtime.exs) with the
  `:demo` script, a markdown answer streamed with short pauses, so the chat can be exercised
  and screenshotted without a key. The script a fresh stream uses when no test set one comes
  from `config :trinity, Trinity.LLM.Providers.Fake, script: :demo`; absent, the default above.
  """
  @behaviour Trinity.LLM.Provider

  alias Trinity.LLM.Error

  @default_script [
    {:text_delta, "Hello, "},
    {:text_delta, "world."},
    {:tool_call_start, "call_1", "get_weather"},
    {:tool_call_delta, "call_1", ~s({"city":)},
    {:tool_call_delta, "call_1", ~s("Paris"})},
    {:tool_call_end, "call_1", %{"city" => "Paris"}},
    {:usage, %{input_tokens: 10, output_tokens: 5}},
    {:done, :tool_calls}
  ]

  @demo_text """
  Hello. I am **Trinity**, running on the scripted provider, so nothing here left the machine.

  Things this answer exercises while it streams:

  - inline `code`, *emphasis* and a [link](https://example.com)
  - a list that grows one item at a time
  - a fenced block:

  ```elixir
  defmodule Trinity.Demo do
    def answer, do: {:ok, "streamed"}
  end
  ```

  | column | value |
  |---|---|
  | deltas | many |
  | patches | few |

  > Raw HTML in the answer is dropped, not rendered: <script>alert(1)</script>

  That is the whole demo.
  """

  @type step :: Trinity.LLM.Event.t() | {:sleep, pos_integer()} | :raise_now

  @doc "The events every following stream emits."
  @spec script([step()]) :: :ok
  def script(events), do: scripts([events])

  @doc "A sequence of scripts, one per stream call, the last one repeating."
  @spec scripts([[step()]]) :: :ok
  def scripts(list) when is_list(list) and list != [] do
    :persistent_term.put({__MODULE__, :scripts}, list)
    :ok
  end

  @doc "Makes the next `n` calls fail with `error` before succeeding."
  @spec fail(non_neg_integer(), Error.t()) :: :ok
  def fail(n, %Error{} = error) do
    :persistent_term.put({__MODULE__, :fail}, {n, error})
    :ok
  end

  @doc "How many calls the provider has served since the last `clear/0`."
  @spec calls() :: non_neg_integer()
  def calls, do: :persistent_term.get({__MODULE__, :calls}, 0)

  @doc "The last request a stream call received, or nil. Slice 013's model-switch test reads it."
  @spec last_request() :: Trinity.LLM.Request.t() | nil
  def last_request, do: :persistent_term.get({__MODULE__, :last_request}, nil)

  @doc "Forgets scripts, pending failures, the call count and the last request."
  @spec clear() :: :ok
  def clear do
    for key <- [:scripts, :fail, :calls, :last_request],
        do: :persistent_term.erase({__MODULE__, key})

    :ok
  end

  @doc "The `:demo` script: the markdown answer above, word by word, 30 ms apart."
  @spec demo_script() :: [step()]
  def demo_script do
    words = Regex.split(~r/(?<=\s)/, @demo_text)
    n = length(words)

    Enum.flat_map(words, &[{:text_delta, &1}, {:sleep, 30}]) ++
      [{:usage, %{input_tokens: 12, output_tokens: n}}, {:done, :stop}]
  end

  @impl true
  def stream(request, _opts, emit) do
    :persistent_term.put({__MODULE__, :last_request}, request)

    with :ok <- maybe_fail() do
      events = next_script()

      Enum.each(events, fn
        {:sleep, ms} -> Process.sleep(ms)
        :raise_now -> raise "the fake provider was told to raise"
        event -> emit.(event)
      end)

      {:ok, usage_of(events)}
    end
  end

  @impl true
  def generate(_request, _opts) do
    with :ok <- maybe_fail() do
      {:ok,
       %{
         text: "Hello, world.",
         tool_calls: [%{id: "call_1", name: "get_weather", args: %{"city" => "Paris"}}],
         usage: %{input_tokens: 10, output_tokens: 5},
         finish: :tool_calls
       }}
    end
  end

  @impl true
  def generate_object(_request, schema, _opts) do
    with :ok <- maybe_fail() do
      object =
        schema
        |> Map.get("properties", %{})
        |> Map.new(fn
          {k, %{"type" => "integer"}} -> {k, 42}
          {k, %{"type" => "number"}} -> {k, 4.2}
          {k, %{"type" => "boolean"}} -> {k, true}
          {k, _} -> {k, "fake"}
        end)

      {:ok, object, %{input_tokens: 8, output_tokens: 4}}
    end
  end

  @impl true
  def embed(texts, opts) do
    with :ok <- maybe_fail() do
      dim = Keyword.get(opts, :dim, 8)
      {:ok, Enum.map(texts, fn _ -> List.duplicate(0.5, dim) end), %{input_tokens: length(texts)}}
    end
  end

  @impl true
  def models, do: ["chat", "embed"]

  @impl true
  def capabilities("embed"), do: [:embed, {:embed_dim, 8}]
  def capabilities(_), do: [:stream, :tools, :json]

  defp next_script do
    case :persistent_term.get({__MODULE__, :scripts}, nil) do
      nil -> configured_script()
      [only] -> only
      [head | rest] -> (:persistent_term.put({__MODULE__, :scripts}, rest) && head) || head
    end
  end

  defp configured_script do
    case Application.get_env(:trinity, __MODULE__, [])[:script] do
      :demo -> demo_script()
      _ -> @default_script
    end
  end

  defp maybe_fail do
    :persistent_term.put({__MODULE__, :calls}, calls() + 1)

    case :persistent_term.get({__MODULE__, :fail}, nil) do
      {n, error} when n > 0 ->
        :persistent_term.put({__MODULE__, :fail}, {n - 1, error})
        {:error, error}

      _ ->
        :ok
    end
  end

  defp usage_of(events) do
    Enum.find_value(events, %{}, fn
      {:usage, usage} -> usage
      _ -> nil
    end)
  end
end
