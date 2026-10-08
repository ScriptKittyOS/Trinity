# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SettingsLiveTest do
  @moduledoc """
  Slice 100, line 9: the Settings page's desktop sections. AC5's automatic half is here: a provider
  key typed into the page goes to the keychain and nowhere else, not to the database file, not to
  the settings file, not to a log line, and the page never shows it back. The keychain is
  `Trinity.FakeKeychain`; the shell is `Trinity.Desktop.Recorder`.
  """
  use TrinityWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Trinity.{FakeKeychain, Gateways, Secrets, Settings}

  @name "TRINITY_TEST_SETTINGS_KEY"

  setup do
    llm = Application.get_env(:trinity, :llm)
    desktop = Application.get_env(:trinity, :desktop)

    model = %{
      id: "keyed:chat",
      provider: :fake,
      model: "chat",
      api_key_env: @name,
      caps: [:stream],
      price: %{input: 0.0, output: 0.0}
    }

    Application.put_env(:trinity, :llm, Keyword.update!(llm, :models, &(&1 ++ [model])))
    Application.put_env(:trinity, :desktop, impl: Trinity.Desktop.Recorder)
    Application.put_env(:trinity, :desktop_recorder, self())
    System.delete_env(@name)

    on_exit(fn ->
      Application.put_env(:trinity, :llm, llm)
      Application.put_env(:trinity, :desktop, desktop)
      Application.delete_env(:trinity, :desktop_recorder)
      System.delete_env(@name)
      File.rm(Settings.path())
      Gateways.resume()
    end)

    :ok
  end

  describe "provider keys (AC5)" do
    test "a key typed in goes to the keychain, is never shown back, and is in no log",
         %{conn: conn} do
      {view, value, log} = submit_key(conn)

      assert {:ok, ^value} = Secrets.fetch(@name)
      assert has_element?(view, "#key-#{@name} [data-source=keychain]")
      refute render(view) =~ value
      refute log =~ value
    end

    # `strings trinity.db | grep`, as AC5 words it, over every database file and the settings
    # file. The databases are the suite's own; the settings file is the page's. SQLite only: on
    # the postgres job there is no database file to read, and the list came back empty.
    @tag :sqlite
    test "a key typed in is in no database file and not in the settings file", %{conn: conn} do
      {_view, value, _log} = submit_key(conn)

      files =
        Path.wildcard(Path.expand("../../../trinity_test*.db*", __DIR__)) ++
          Enum.filter([Settings.path()], &File.exists?/1)

      assert files != []

      for file <- files do
        refute File.read!(file) =~ value, "#{file} holds the key in clear"
      end
    end

    test "the form's parameter is one Phoenix and LiveView log as [FILTERED]" do
      assert Phoenix.Logger.filter_values(%{"name" => @name, "secret" => %{"value" => "sk-x"}}) ==
               %{"name" => @name, "secret" => "[FILTERED]"}
    end

    test "remove deletes it from the keychain", %{conn: conn} do
      FakeKeychain.install!()
      :ok = Secrets.store(@name, "sk-test-remove-me")
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("#key-#{@name} button", "Remove") |> render_click()
      assert {:error, :not_found} = Secrets.fetch(@name)
      assert has_element?(view, "#key-#{@name} [data-source=none]")
    end

    test "with no keychain the page says so and offers no field that would store the key elsewhere",
         %{conn: conn} do
      Application.delete_env(:trinity, :secrets)
      System.put_env(@name, "from-env")
      {:ok, view, html} = live(conn, ~p"/settings")
      assert has_element?(view, "#key-#{@name} [data-source=env]")
      assert html =~ "No keychain"
      refute has_element?(view, "#key-#{@name} input[name='secret[value]']:not([disabled])")
    end
  end

  describe "desktop" do
    test "the hotkey is saved and handed to the shell; a malformed one is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#hotkey-form", %{"hotkey" => "CommandOrControl+Shift+K"})
      |> render_submit()

      assert Settings.get(:hotkey) == "CommandOrControl+Shift+K"
      assert_receive {:desktop, :set_hotkey, ["CommandOrControl+Shift+K"]}

      html = view |> form("#hotkey-form", %{"hotkey" => "banana"}) |> render_submit()
      assert html =~ "not a shortcut"
      assert Settings.get(:hotkey) == "CommandOrControl+Shift+K"
    end

    test "notifications can be muted, and launch at login handed to the shell", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("#notifications-muted") |> render_click()
      assert Settings.get(:notifications_muted) == true
      view |> element("#autostart") |> render_click()
      assert Settings.get(:autostart) == true
      assert_receive {:desktop, :set_autostart, [true]}
    end

    test "a folder picked in the native dialog becomes a root the tools may use", %{conn: conn} do
      dir = Path.join(System.tmp_dir!(), "picked-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:trinity, :desktop_recorder_dialog, [dir])

      on_exit(fn ->
        Application.delete_env(:trinity, :desktop_recorder_dialog)
        File.rm_rf!(dir)
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("#pick-root") |> render_click()
      assert_receive {:desktop, :open_dialog, [opts]}
      assert opts[:kind] == :folder
      assert render_async(view) =~ dir
      assert dir in Settings.get(:fs_roots)
      assert Path.expand(dir) in Trinity.Tools.FS.roots()
    end

    test "a folder typed in is accepted only if it is an existing absolute directory", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = view |> form("#root-form", %{"root" => "relative/path"}) |> render_submit()
      assert html =~ "absolute"
      assert Settings.get(:fs_roots) == []

      tmp = System.tmp_dir!()
      view |> form("#root-form", %{"root" => tmp}) |> render_submit()
      assert Settings.get(:fs_roots) == [tmp]
      view |> element("#roots [data-root='#{tmp}'] button", "Remove") |> render_click()
      assert Settings.get(:fs_roots) == []
    end

    test "the gateways can be paused from here as from the tray", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("#gateways-pause") |> render_click()
      assert Gateways.paused?()
      assert render(view) =~ "paused"
    end

    test "the data directory and the budgets in force are shown", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ Trinity.Paths.data_dir()
      assert html =~ "Budgets"
    end
  end

  # Types a fresh key into the page's form; returns the view, the key and the log of the submit.
  defp submit_key(conn) do
    FakeKeychain.install!()
    value = "sk-test-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    {:ok, view, html} = live(conn, ~p"/settings")
    assert html =~ @name
    assert has_element?(view, "#key-#{@name} [data-source=none]")

    log =
      capture_log([level: :debug], fn ->
        view
        |> form("#key-#{@name}", %{"secret" => %{"value" => value}})
        |> render_submit()
      end)

    {view, value, log}
  end
end
