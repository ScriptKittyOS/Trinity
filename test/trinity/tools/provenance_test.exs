# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.ProvenanceTest do
  @moduledoc """
  Slice 022 AC11 (M1): a summary of an untrusted page is itself tagged untrusted, and an
  instruction inside the page reaches the model only inside an `<untrusted>` block the system
  prompt names as data.
  """
  use Trinity.SessionCase
  @moduletag :capture_log

  alias Trinity.Content.Part
  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Sessions.Prompt

  setup do
    previous = Application.get_env(:trinity, :web, [])

    Application.put_env(
      :trinity,
      :web,
      Keyword.put(previous, :req_options, plug: Trinity.FakeWeb)
    )

    on_exit(fn -> Application.put_env(:trinity, :web, previous) end)
    row = Factory.session!()
    :ok = Sessions.subscribe(row.id)
    {:ok, id: row.id}
  end

  test "the assistant's summary of a fetched page carries taint untrusted; the user's message stays trusted",
       %{id: id} do
    Fake.scripts([
      [
        {:tool_call_start, "c1", "web_fetch"},
        {:tool_call_end, "c1", %{"url" => "http://example.test/page"}},
        {:usage, %{input_tokens: 1, output_tokens: 1}},
        {:done, :tool_calls}
      ],
      script_deltas(3, "summary ")
    ])

    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "summarise http://example.test/page")
    _ = collect(id, &match?({:state, :idle}, &1), 10_000)
    history = Sessions.history(id)
    assert Enum.map(history, & &1.role) == ["user", "assistant", "tool", "assistant"]
    [user, first, tool, summary] = history
    assert Prompt.taint_of(user) == :trusted

    assert first.parts["taint"] == "trusted",
           "the turn that asked for the page had read nothing untrusted"

    assert tool.parts["taint"] == "untrusted"

    assert [%{"origin" => "tool:web_fetch", "taint" => "untrusted", "digest" => d}] =
             tool.parts["content_parts"]

    assert d == Part.digest(tool.parts["tool_result"]["content"])
    assert summary.parts["taint"] == "untrusted"
    assert Part.max_taint([:trusted, :untrusted]) == :untrusted

    # A later turn that reads the history inherits it too.
    Fake.script(script_deltas(1, "later"))
    {:ok, _} = Session.send_user_message(pid, "and now?")
    _ = collect(id, &match?({:state, :idle}, &1))
    assert List.last(Sessions.history(id)).parts["taint"] == "untrusted"
  end

  test "the instruction inside the page is rendered only inside an <untrusted> block, and the system prompt states the rule",
       %{id: id} do
    Fake.scripts([
      [
        {:tool_call_start, "c1", "web_fetch"},
        {:tool_call_end, "c1", %{"url" => "http://example.test/page"}},
        {:usage, %{input_tokens: 1, output_tokens: 1}},
        {:done, :tool_calls}
      ],
      script_deltas(1, "ok")
    ])

    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "read it")
    _ = collect(id, &match?({:state, :idle}, &1), 10_000)

    # The request the final turn was built from, rebuilt from the same rows.
    request = Prompt.build(Sessions.get_session(id), nil, Sessions.history(id), [])
    injected = Trinity.FakeWeb.injected()
    assert request.system =~ Prompt.untrusted_rule()
    refute request.system =~ injected

    tool_msg = Enum.find(request.messages, &(&1.role == "tool"))
    assert tool_msg.content =~ injected

    assert tool_msg.content =~
             ~s(<untrusted source="tool:web_fetch" ref="http://example.test/page" digest=")

    assert String.ends_with?(String.trim(tool_msg.content), "</untrusted>")
    [before, _] = String.split(tool_msg.content, injected, parts: 2)
    assert before =~ "<untrusted", "the instruction sits after the opening tag"

    for m <- request.messages,
        m.role != "tool",
        do: refute(m.content =~ injected, "#{m.role} carries the instruction")
  end
end
