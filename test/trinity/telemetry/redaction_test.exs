# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Telemetry.RedactionTest do
  @moduledoc """
  Slice 090, AC4: a credential in a log message is masked.

  The tests here also state what the filter does **not** catch, in the same file, because a
  redaction filter that is trusted beyond its reach is worse than none: it turns "we mask secrets"
  into a belief rather than a mechanism. The controls are elsewhere (keys in files, no token in
  records, no content in telemetry); this is a last line and the tests say so.
  """
  use ExUnit.Case, async: true

  alias Trinity.Telemetry.Redaction

  describe "what it masks" do
    test "an authorization header, however it is spelled" do
      for prefix <- ~w(Bearer bearer Token basic) do
        line = "GET /v1/models #{prefix} abcdefghijklmnopqrstuvwxyz123456"
        out = Redaction.redact(line)
        assert out =~ "[REDACTED]"
        refute out =~ "abcdefghijklmnopqrstuvwxyz123456"
      end
    end

    test "a provider key, by its shape rather than by its name" do
      line = "calling openai with sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz012345"
      out = Redaction.redact(line)
      refute out =~ "AbCdEfGhIjKlMnOpQrStUvWxYz012345"
      assert out =~ "[REDACTED]"
    end

    test "a JSON web token" do
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1g"
      assert Redaction.redact("token=#{jwt}") =~ "[REDACTED"
      refute Redaction.redact("token=#{jwt}") =~ "dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1g"
    end

    test "a named secret in a key/value position" do
      for line <- [
            "password: hunter2-and-then-some",
            "api_key=sk_live_something_long_here",
            "access-token = zzzzzzzzzzzzzzzzzzzz",
            "PRIVATE_KEY:abcdefghijklmnop"
          ] do
        out = Redaction.redact(line)
        assert out =~ "[REDACTED]", "not masked: #{line} -> #{out}"
      end
    end

    test "it masks inside a Logger event's message and metadata, and never drops the event" do
      event = %{
        msg: {:string, "connecting with Bearer abcdefghijklmnopqrstuvwxyz"},
        meta: %{header: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz", session_id: "s-1"}
      }

      out = Redaction.filter(event, nil)

      assert {:string, masked} = out.msg
      assert masked =~ "[REDACTED]"
      refute masked =~ "abcdefghijklmnopqrstuvwxyz"
      refute out.meta.header =~ "abcdefghijklmnopqrstuvwxyz"

      # The event survives: a filter that drops a line to avoid printing a secret also drops the
      # evidence that something happened.
      assert out.meta.session_id == "s-1"
    end
  end

  describe "truncation" do
    test "a long message is cut and says how much was dropped" do
      long = String.duplicate("x", Redaction.max_chars() + 500)
      out = Redaction.truncate(long)

      assert String.length(out) < String.length(long)
      assert out =~ "500 more characters"
    end

    test "a short message is untouched" do
      assert Redaction.truncate("short") == "short"
    end
  end

  describe "what it does not catch, stated rather than left to be discovered" do
    test "a credential with no recognisable shape passes through" do
      # This is the filter's honest limit. It matches shapes, and a secret that looks like an
      # ordinary word is an ordinary word to it.
      line = "the passphrase is correct horse battery staple"
      assert Redaction.redact(line) == line
    end

    test "content that merely looks like a credential is masked, and that is the right trade" do
      # Over-masking costs a reader context; under-masking puts a key on disk.
      line = "the user wrote: my password: is a secret I keep"
      assert Redaction.redact(line) =~ "[REDACTED]"
    end
  end
end
