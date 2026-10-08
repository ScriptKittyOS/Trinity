# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SetupLiveTest do
  @moduledoc """
  Slice 100, AC11's automatic half: on a machine with nothing configured, `/` leads to `/setup`,
  which takes a person through a model and its key, the data directory and the first project
  folders, and ends in a new session. The manual half, a fresh account and a real key reaching a
  working first turn, is in the manual queue.

  "Nothing configured" is measured, not assumed: the default model needs a key that neither the
  keychain nor the environment has, and the setup has not been completed. The suite's own default
  model needs no key, which is why every other LiveView test still lands on the sessions index.
  """
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.{FakeKeychain, Secrets, Settings}

  @name "TRINITY_TEST_SETUP_KEY"

  setup do
    llm = Application.get_env(:trinity, :llm)

    keyed = %{
      id: "keyed:setup",
      provider: :fake,
      model: "chat",
      api_key_env: @name,
      caps: [:stream, :tools],
      price: %{input: 0.0, output: 0.0}
    }

    Application.put_env(
      :trinity,
      :llm,
      llm |> Keyword.update!(:models, &(&1 ++ [keyed])) |> Keyword.put(:default_model, keyed.id)
    )

    System.delete_env(@name)

    on_exit(fn ->
      Application.put_env(:trinity, :llm, llm)
      System.delete_env(@name)
      File.rm(Settings.path())
      Trinity.SessionCase.stop_all_sessions()
    end)

    :ok
  end

  test "with nothing configured, / leads to /setup", %{conn: conn} do
    assert Trinity.Setup.needed?()
    assert {:error, {:live_redirect, %{to: "/setup"}}} = live(conn, ~p"/")
  end

  test "a key already in the environment means there is nothing to set up", %{conn: conn} do
    System.put_env(@name, "from-env")
    refute Trinity.Setup.needed?()
    assert {:ok, _view, _html} = live(conn, ~p"/")
  end

  test "AC11: model and key, data directory, project folders, then a session", %{conn: conn} do
    FakeKeychain.install!()
    folder = System.tmp_dir!()
    {:ok, view, html} = live(conn, ~p"/setup")
    assert html =~ "keyed:setup"

    view
    |> form("#setup-model", %{"setup" => %{"model" => "keyed:setup", "secret" => "sk-test-setup"}})
    |> render_submit()

    assert {:ok, "sk-test-setup"} = Secrets.fetch(@name)
    assert render(view) =~ Trinity.Paths.data_dir()

    view |> element("#setup-data-dir button", "Use this folder") |> render_click()

    view |> form("#root-form", %{"root" => folder}) |> render_submit()
    assert Settings.get(:fs_roots) == [folder]

    view |> element("#setup-finish") |> render_click()
    {path, _flash} = assert_redirect(view)
    assert "/s/" <> _id = path

    refute Trinity.Setup.needed?()
    assert Trinity.LLM.default_model() == "keyed:setup"
    assert {:ok, _view, _html} = live(conn, ~p"/")
  end

  test "a model whose key is missing cannot be finished past, and the reason is shown", %{
    conn: conn
  } do
    FakeKeychain.install!()
    {:ok, view, _html} = live(conn, ~p"/setup")

    html =
      view
      |> form("#setup-model", %{"setup" => %{"model" => "keyed:setup", "secret" => ""}})
      |> render_submit()

    assert html =~ "needs a key"
    refute has_element?(view, "#setup-finish")
  end
end
