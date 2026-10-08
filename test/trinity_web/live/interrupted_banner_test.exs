# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.InterruptedBannerTest do
  @moduledoc """
  Slice 100, AC7's relaunch half. Until this slice the banner appeared only when the page saw
  `{:turn_interrupted, _}`, which the session broadcasts when it rehydrates a leftover *draft*.
  A turn the quit path has already finalised as interrupted (`Trinity.Sessions.ShutdownTest`)
  leaves no draft, so nothing was broadcast and the relaunched page showed no banner. The page now
  reads the newest row when it mounts.
  """
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.Factory

  setup do
    on_exit(fn -> Trinity.SessionCase.stop_all_sessions() end)
    {:ok, session: Factory.session!()}
  end

  test "the newest row interrupted at quit: the banner shows on mount, with Retry", %{
    conn: conn,
    session: s
  } do
    Factory.message!(s.id, %{role: "user", content: "go"})

    Factory.message!(s.id, %{
      role: "assistant",
      content: "Partial answer",
      parts: %{"interrupted" => true, "draft" => false, "interrupted_reason" => "shutdown"}
    })

    {:ok, view, _html} = live(conn, ~p"/s/#{s.id}")
    assert has_element?(view, "#banner", "interrupted")
    assert has_element?(view, "#banner button", "Retry")
  end

  test "an ordinary last reply shows no banner", %{conn: conn, session: s} do
    Factory.message!(s.id, %{role: "user", content: "go"})
    Factory.message!(s.id, %{role: "assistant", content: "Done.", parts: %{"draft" => false}})
    {:ok, view, _html} = live(conn, ~p"/s/#{s.id}")
    refute has_element?(view, "#banner")
  end

  test "an interrupted reply followed by a newer message is history, not a banner", %{
    conn: conn,
    session: s
  } do
    Factory.message!(s.id, %{role: "user", content: "go"})

    Factory.message!(s.id, %{
      role: "assistant",
      content: "Partial",
      parts: %{"interrupted" => true, "draft" => false}
    })

    Factory.message!(s.id, %{role: "user", content: "again"})
    Factory.message!(s.id, %{role: "assistant", content: "Done.", parts: %{"draft" => false}})
    {:ok, view, _html} = live(conn, ~p"/s/#{s.id}")
    refute has_element?(view, "#banner")
  end
end
