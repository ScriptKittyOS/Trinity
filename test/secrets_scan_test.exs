# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule SecretsScanTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Trinity.Secrets.Scan

  # Every fixture is COMPOSED at runtime. Writing a whole key shape literally would make this
  # file a finding, and the scanner's skip list is not allowed to grow to cover it.
  test "RED: a planted fake key of each shape is found" do
    assert [{"AWS access key id", 1}] = Scan.findings("AKIA" <> "IOSFODNN7EXAMPLE")
    assert [{"GitHub token", 1}] = Scan.findings("ghp_" <> String.duplicate("a", 36))
    assert [{"Slack token", 1}] = Scan.findings("xox" <> "b-1234567890-abcdefghij")
    assert [{"private key block", 1}] = Scan.findings("-----BEGIN " <> "PRIVATE KEY-----")
  end

  test "RED: a long secret assignment is found, and the line number is reported" do
    text = "config = []\napi_key = \"" <> String.duplicate("A", 30) <> "\"\n"
    assert [{"generic long secret assignment", 2}] = Scan.findings(text)
  end

  # Slice 071. A Telegram bot token is the bot's numeric id, a colon, and 35 characters that
  # begin "AA". Composed, as above. The suite's own fake token is not this shape on purpose.
  test "RED: a Telegram bot token is found; the suite's fake token is not one" do
    token = "123456789:" <> "AA" <> String.duplicate("b", 33)
    assert [{"Telegram bot token", 1}] = Scan.findings("TELEGRAM_BOT_TOKEN=" <> token)
    assert Scan.findings("071000001:TEST_fake_token_for_the_suite_only") == []
  end

  # Slice 072. A Mattermost token is 26 lower-case letters and digits, the shape of every id the
  # server issues, so only a named assignment is a finding. Composed, as above.
  test "RED: a Mattermost token assigned by name is found; an id of the same shape is not" do
    token = "abc" <> String.duplicate("7", 23)
    assert [{"Mattermost token assignment", 1}] = Scan.findings("MATTERMOST_BOT_TOKEN=" <> token)
    assert Scan.findings(~s|channel_id: "#{token}"|) == []
  end

  test "GREEN: ordinary source is clean" do
    assert Scan.findings("def hello, do: :world\n# AKIA is mentioned but not a key\n") == []
  end

  test "GREEN: a short assignment is not a finding, because it is a tripwire not a parser" do
    assert Scan.findings(~s|api_key = "short"|) == []
  end
end
