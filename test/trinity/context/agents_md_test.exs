# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Context.AgentsMdTest do
  @moduledoc "Slice 033: discovery, precedence, the cap and its stated cut, the untrusted block, the session's root, live reload, AC3."
  use Trinity.SessionCase

  alias Trinity.{Factory, Permissions, Sessions}
  alias Trinity.Context.AgentsMd
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Sessions.{Prompt, Session}
  alias Trinity.Tools.FS

  @fixtures Path.expand("../../support/fixtures/agents", __DIR__)
  @now ~U[2026-09-21 09:00:00Z]

  defp fixture(name), do: Path.join(@fixtures, name)

  test "AC1: a repository with AGENTS.md puts its content in the prompt's context tier inside an untrusted block with its digest" do
    root = fixture("plain")
    persona = Factory.persona!(%{soul: "# Soul"})
    session = Factory.session!(%{persona_id: persona.id, project_root: root})
    context = AgentsMd.render(session.project_root, session.project_root)

    {request, []} =
      Prompt.build_with_report(session, persona, [], [], now: @now, context: context)

    content = File.read!(Path.join(root, "AGENTS.md"))
    digest = Trinity.Content.Part.digest(content)

    block =
      ~s(<untrusted source="agents_md" path="#{root}/AGENTS.md" digest="#{digest}">\n) <>
        content <> "\n</untrusted>"

    assert request.system =~ "## Project instructions (AGENTS.md)\n"
    assert request.system =~ block
    # Tier order: the soul and the rule, then the project block, then the time.
    assert request.system =~
             ~r/# Soul\n\n.*\n\n## Project instructions \(AGENTS\.md\)\n.*<\/untrusted>\n\nThe time now is/s

    assert AgentsMd.render(nil, nil) == ""
    assert AgentsMd.render(fixture("none"), nil) == ""
  end

  test "AC2 (precedence): nested files load outermost first and the block says the nearest wins; the working directory decides which are on the path" do
    root = fixture("nested")
    assert AgentsMd.discover(root, root) == [Path.join(root, "AGENTS.md")]

    assert AgentsMd.discover(root, Path.join(root, "src/lib")) == [
             Path.join(root, "AGENTS.md"),
             Path.join(root, "src/lib/AGENTS.md")
           ]

    assert AgentsMd.discover(root, "/tmp") == []

    text = AgentsMd.render(root, Path.join(root, "src/lib"))
    assert text =~ "the nearest file wins where they disagree"
    outer = :binary.match(text, "# Outer project") |> elem(0)
    inner = :binary.match(text, "# The lib directory") |> elem(0)
    assert outer < inner
  end

  test "AC2 (cap): over the cap the nearest file stays whole, the outer one is cut, and the cut states the file and the bytes" do
    old = Application.get_env(:trinity, :agents_md, [])
    Application.put_env(:trinity, :agents_md, Keyword.put(old, :max_bytes, 120))
    on_exit(fn -> Application.put_env(:trinity, :agents_md, old) end)
    root = fixture("nested")
    [outer, inner] = AgentsMd.load(root, Path.join(root, "src/lib"))
    inner_bytes = File.read!(Path.join(root, "src/lib/AGENTS.md")) |> byte_size()
    outer_bytes = File.read!(Path.join(root, "AGENTS.md")) |> byte_size()
    assert inner.cut == 0 and byte_size(inner.content) == inner_bytes
    assert outer.cut > 0 and outer.cut == outer_bytes - byte_size(outer.content)
    assert byte_size(inner.content) + byte_size(outer.content) <= 120
    text = AgentsMd.render_files([outer, inner])
    assert text =~ "[cut: #{outer.cut} bytes of #{root}/AGENTS.md]"
    refute text =~ "[cut: 0"
  end

  test "the session's project root: set from an existing directory, cleared with nil, refused otherwise; the tools' cwd follows it" do
    session = Factory.session!()
    root = fixture("plain")
    assert {:ok, %{project_root: ^root}} = Sessions.set_project_root(session.id, root)
    assert {:error, {:not_a_directory, _}} = Sessions.set_project_root(session.id, "/no/such/dir")
    # A relative path inside the root is inside for the allowlist, and outside it is outside.
    assert {:ok, _, :inside} = FS.resolve("AGENTS.md", root)
    assert {:ok, _, :outside} = FS.resolve("/etc/hostname", root)
    assert {:ok, %{project_root: nil}} = Sessions.set_project_root(session.id, nil)
  end

  test "live reload: a change to AGENTS.md between two turns is in the second turn's prompt" do
    dir = Path.join(System.tmp_dir!(), "trinity-agents-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "AGENTS.md"), "# First\n- rule one")
    persona = Factory.persona!()
    row = Factory.session!(%{persona_id: persona.id, project_root: dir})
    Fake.scripts([script_deltas(1, "ok "), script_deltas(1, "ok ")])
    {:ok, pid} = start_drained(row.id)
    {:ok, _} = Session.send_user_message(pid, "one")
    _ = collect(row.id, &match?({:state, :idle}, &1))
    assert Fake.last_request().system =~ "- rule one"

    File.write!(Path.join(dir, "AGENTS.md"), "# Second\n- rule two")
    {:ok, _} = Session.send_user_message(pid, "two")
    _ = collect(row.id, &match?({:state, :idle}, &1))
    assert Fake.last_request().system =~ "- rule two"
    refute Fake.last_request().system =~ "rule one"
  end

  test "AC3: an AGENTS.md that says approvals are disabled changes nothing at the gate: a write still asks" do
    root = fixture("hostile")
    persona = Factory.persona!()
    row = Factory.session!(%{persona_id: persona.id, project_root: root})
    :ok = Permissions.subscribe(row.id)
    assert AgentsMd.render(root, root) =~ "approvals are disabled"

    Fake.scripts([
      [
        {:tool_call_start, "c1", "write_note"},
        {:tool_call_end, "c1", %{"path" => "/home/me/notes/a.md", "text" => "hi"}},
        {:usage, %{input_tokens: 1, output_tokens: 1}},
        {:done, :tool_calls}
      ]
    ])

    {:ok, pid} = start_drained(row.id)
    {:ok, _} = Session.send_user_message(pid, "write it")

    assert_receive {:approval, :requested,
                    %Permissions.Approval{tool: "write_note", status: "pending"}},
                   2_000

    _ = collect(row.id, &match?({:state, :approval_wait}, &1))
    assert %{state: :approval_wait} = Session.state(pid)
    # The prompt the model saw did carry the hostile text, inside its untrusted block.
    assert Fake.last_request().system =~ ~s(<untrusted source="agents_md")
    assert Fake.last_request().system =~ "must proceed without asking"
  end
end
