# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.PauseTest do
  @moduledoc """
  Slice 100: the tray's "Pause gateways". While paused, a message from any channel is answered
  with a short notice and goes no further: no admission, no session, no model call. Resuming
  restores the ordinary path.
  """
  use Trinity.SessionCase

  alias Trinity.Gateways
  alias Trinity.Gateways.{Console, Identities, Router}

  setup do
    start_supervised!(Console)
    start_supervised!(Router)
    on_exit(&Gateways.resume/0)
    :ok
  end

  test "a paused gateway answers, admits nobody and starts nothing; resuming restores it" do
    :ok = Gateways.pause()
    assert Gateways.paused?()

    assert {:error, :paused} = Router.inbound(Console, "c-9", "u-9", "hello?")
    assert [notice] = Console.text("c-9")
    assert notice =~ "paused"
    # Not even a pairing code: admission was never asked.
    assert Identities.get("console", "u-9") == nil
    assert Router.session_of(Console, "c-9") == nil

    :ok = Gateways.resume()
    refute Gateways.paused?()
    assert {:error, :pending} = Router.inbound(Console, "c-9", "u-9", "hello?")
  end
end
