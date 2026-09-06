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

  test "GREEN: ordinary source is clean" do
    assert Scan.findings("def hello, do: :world\n# AKIA is mentioned but not a key\n") == []
  end

  test "GREEN: a short assignment is not a finding, because it is a tripwire not a parser" do
    assert Scan.findings(~s|api_key = "short"|) == []
  end
end
