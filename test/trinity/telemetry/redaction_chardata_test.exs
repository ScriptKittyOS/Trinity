# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Telemetry.RedactionChardataTest do
  @moduledoc """
  Slice 125: the redaction filter walks chardata, never raises, and can never be left out.

  The defect: `filter/2` called `Enum.map/2` on the message body, OTP chardata is routinely an
  **improper** list whose tail is a binary rather than `[]`, `Enum.map/2` raises
  `FunctionClauseError` on one, and OTP responds to a raising primary filter by removing it from the
  handler permanently. Everything logged afterwards is unredacted and nothing says so.

  Observed twice on a running server, including at boot from an `Exqlite.Error`, so it needs no
  exotic conditions. The suite never saw it because the suite only ever fed the filter proper lists.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trinity.Telemetry.Redaction

  # The exact event from the live log, tail and all. The `|` before the last element is the defect:
  # this is an improper list.
  defp live_event do
    %{
      level: :error,
      meta: %{
        line: 124,
        pid: self(),
        file: ~c"lib/db_connection/connection.ex",
        domain: [:elixir],
        application: :db_connection,
        mfa: {DBConnection.Connection, :handle_event, 4}
      },
      msg:
        {:string,
         [
           "Exqlite.Connection",
           32,
           40,
           "#PID<0.810.0> (\"db_conn_2\")",
           ") failed to connect: " | "** (Exqlite.Error) database is locked"
         ]}
    }
  end

  defp text(%{msg: msg}), do: msg |> flatten_msg() |> IO.iodata_to_binary()

  defp flatten_msg({:string, cd}), do: cd
  defp flatten_msg({:report, r}), do: inspect(r)
  defp flatten_msg({fmt, args}) when is_list(args), do: :io_lib.format(fmt, args)

  # Chardata that includes the shape the suite never generated: a list whose tail is a binary
  # rather than `[]`. StreamData's own `chardata/0` builds proper lists only, which is exactly why
  # a property over it would have gone on passing while the filter died in production.
  defp mixed_chardata do
    leaf =
      one_of([
        string(:printable),
        integer(32..126),
        list_of(integer(32..126), max_length: 4)
      ])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 4),
        bind({list_of(child, max_length: 3), string(:printable)}, fn {items, tail} ->
          constant(improper(items, tail))
        end)
      ])
    end)
  end

  defp improper([], tail), do: tail
  defp improper([h | t], tail), do: [h | improper(t, tail)]

  describe "AC1: the event that killed it" do
    test "filter/2 does not raise on the improper chardata from the live log" do
      assert %{msg: _, meta: _} = Redaction.filter(live_event(), nil)
    end

    test "and the message survives it: the tail is still in the output" do
      out = Redaction.filter(live_event(), nil)
      assert text(out) =~ "database is locked"
      assert text(out) =~ "Exqlite.Connection"
    end
  end

  describe "AC2: total over OTP's message shapes" do
    test "a binary" do
      out = Redaction.filter(%{msg: {:string, "plain"}, meta: %{}, level: :info}, nil)
      assert text(out) == "plain"
    end

    test "a proper iolist" do
      ev = %{msg: {:string, ["a", 32, ["b", "c"]]}, meta: %{}, level: :info}
      assert text(Redaction.filter(ev, nil)) == "a bc"
    end

    test "an improper iolist with a binary tail" do
      ev = %{msg: {:string, ["a", 32 | "tail"]}, meta: %{}, level: :info}
      assert text(Redaction.filter(ev, nil)) == "a tail"
    end

    test "a deeply nested improper iolist" do
      ev = %{msg: {:string, ["a", ["b", ["c" | "d"] | "e"] | "f"]}, meta: %{}, level: :info}
      assert text(Redaction.filter(ev, nil)) == "abcdef"
    end

    test "a charlist" do
      ev = %{msg: {:string, ~c"hello"}, meta: %{}, level: :info}
      assert text(Redaction.filter(ev, nil)) == "hello"
    end

    test "a format string with args" do
      ev = %{msg: {~c"~ts and ~ts", ["a", "b"]}, meta: %{}, level: :info}
      out = Redaction.filter(ev, nil)
      assert {_fmt, args} = out.msg
      assert is_list(args)
    end

    test "a report as a map" do
      ev = %{msg: {:report, %{a: 1}}, meta: %{}, level: :info}
      assert %{msg: {:report, %{a: 1}}} = Redaction.filter(ev, nil)
    end

    test "a report as a keyword list" do
      ev = %{msg: {:report, [a: 1, b: "x"]}, meta: %{}, level: :info}
      assert %{msg: {:report, _}} = Redaction.filter(ev, nil)
    end

    test "metadata carrying an improper iolist does not raise either" do
      ev = %{msg: {:string, "x"}, meta: %{weird: ["a" | "b"]}, level: :info}
      assert %{meta: %{weird: _}} = Redaction.filter(ev, nil)
    end
  end

  describe "AC4: it redacts what it walks, including the tail" do
    test "a credential in an improper list's binary tail is masked" do
      ev = %{
        msg: {:string, ["auth: " | "Bearer abcdefghijklmnopqrstuvwxyz0123456789"]},
        meta: %{},
        level: :info
      }

      out = text(Redaction.filter(ev, nil))

      assert out =~ "[REDACTED]",
             "the credential in the improper tail was not masked. The old code could not reach " <>
               "it at all: Enum.map/2 raised before it got there. Output: #{out}"

      refute out =~ "abcdefghijklmnopqrstuvwxyz0123456789"
    end

    test "a credential nested inside a proper list is masked" do
      ev = %{
        # The separators matter and are not padding: flattened, `["x", ["password=..."]]` is
        # "xpassword=...", where `\b` correctly finds no word boundary. The fixture has to be a
        # line someone could actually log.
        msg: {:string, ["connecting ", ["password=hunter2seventeen", " ok"]]},
        meta: %{},
        level: :info
      }

      assert text(Redaction.filter(ev, nil)) =~ "[REDACTED]"
    end
  end

  describe "AC3/AC5: it cannot raise, on anything" do
    property "filter/2 returns for any generated chardata, proper or improper" do
      check all(cd <- mixed_chardata()) do
        ev = %{msg: {:string, cd}, meta: %{}, level: :info}
        assert %{msg: {:string, _}} = Redaction.filter(ev, nil)
      end
    end

    property "and its output is always valid chardata" do
      check all(cd <- mixed_chardata()) do
        ev = %{msg: {:string, cd}, meta: %{}, level: :info}
        %{msg: {:string, out}} = Redaction.filter(ev, nil)
        assert is_binary(IO.iodata_to_binary(out))
      end
    end

    property "filter/2 returns for an arbitrary term in msg or meta" do
      check all(t <- term()) do
        assert %{} = Redaction.filter(%{msg: {:string, t}, meta: %{k: t}, level: :info}, nil)
        assert %{} = Redaction.filter(%{msg: {:report, t}, meta: %{}, level: :info}, nil)
      end
    end
  end

  describe "AC5: the filter is never silently absent" do
    test "it is installed, read from the logger rather than from configuration" do
      names = for {name, _} <- :logger.get_primary_config().filters, do: name
      assert :trinity_redaction in names
    end

    test "it is still installed after being driven with every shape above" do
      for ev <- [
            live_event(),
            %{msg: {:string, ["a" | "b"]}, meta: %{}, level: :info},
            %{msg: {:report, [a: 1]}, meta: %{}, level: :info}
          ] do
        Redaction.filter(ev, nil)
      end

      names = for {name, _} <- :logger.get_primary_config().filters, do: name

      assert :trinity_redaction in names,
             "the filter was removed. OTP removes a primary filter that raises, permanently, and " <>
               "everything logged afterwards is unredacted while the system believes it is not."
    end

    test "logging improper chardata through OTP itself leaves the filter installed" do
      # The end-to-end one. Everything above calls filter/2 directly, which is not how it dies:
      # OTP calls it, OTP catches the raise, and OTP removes it. This goes through the real logger.
      ExUnit.CaptureLog.capture_log(fn ->
        :logger.log(:error, ["Exqlite.Connection", 32, ") failed: " | "** (Exqlite.Error) locked"])

        :logger.log(:error, ["auth " | "Bearer abcdefghijklmnopqrstuvwxyz0123"])
      end)

      names = for {name, _} <- :logger.get_primary_config().filters, do: name

      assert :trinity_redaction in names,
             "OTP removed the filter after logging improper chardata. This is the exact failure " <>
               "seen on the running server: {removed_failing_filter, trinity_redaction}."
    end

    test "and what it logged was redacted, not passed through" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :logger.log(:error, ["auth " | "Bearer abcdefghijklmnopqrstuvwxyz0123"])
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "abcdefghijklmnopqrstuvwxyz0123"
    end

    test "verify_log_redaction!/0 raises when the filter is absent, so boot cannot continue unfiltered" do
      :ok = :logger.remove_primary_filter(:trinity_redaction)

      on_exit(fn ->
        :logger.add_primary_filter(
          :trinity_redaction,
          {&Trinity.Telemetry.Redaction.filter/2, nil}
        )
      end)

      assert_raise RuntimeError, ~r/redaction/i, fn ->
        Trinity.Application.verify_log_redaction!()
      end

      :ok =
        :logger.add_primary_filter(
          :trinity_redaction,
          {&Trinity.Telemetry.Redaction.filter/2, nil}
        )

      assert Trinity.Application.verify_log_redaction!() == :ok
    end
  end
end
