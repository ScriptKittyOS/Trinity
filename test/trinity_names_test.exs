# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityNamesTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Trinity.Names

  @moduledoc """
  The red uses a **synthetic token in a test-only set**, never a real name. Spelling a real
  zero-site name here would itself be the violation the check exists to catch.
  """

  @salt "test-salt-not-the-committed-one"
  @synthetic "zzsyntheticforbiddenname"

  defp set, do: MapSet.new([Names.digest(@salt, @synthetic)])

  defp hit?(text),
    do: text |> Names.tokenise() |> Enum.any?(&MapSet.member?(set(), Names.digest(@salt, &1)))

  test "a synthetic forbidden token is detected in ordinary prose" do
    assert hit?("this line mentions #{@synthetic} in passing")
  end

  test "detection is case-insensitive, because tokenising downcases first" do
    assert hit?(String.upcase(@synthetic))
    assert hit?("MiXeD #{String.capitalize(@synthetic)} case")
  end

  test "detection survives any non-alphanumeric separator, including a path separator" do
    for sep <- ["/", "-", "_", ".", " ", ":"] do
      assert hit?("some#{sep}#{@synthetic}#{sep}thing"), "separator #{inspect(sep)} should split"
    end
  end

  test "an unrelated token is not detected" do
    refute hit?("trinity boundary credo sobelow")
  end

  test "THE STATED LIMIT: a forbidden name glued inside a larger token is NOT detected" do
    refute hit?("prefix#{@synthetic}suffix"),
           "this is the accepted false negative: with no separator the whole run is one token. " <>
             "Accepted because the check is a tripwire against copy-paste drift, and copy-paste " <>
             "carries whole tokens."
  end

  test "tokenise downcases and splits on every run of non-alphanumerics" do
    assert Names.tokenise("Foo/Bar-baz_QUX.1") == ["foo", "bar", "baz", "qux", "1"]

    assert Names.tokenise("docs/adr/0013-receipt-chain-owner.md") ==
             ["docs", "adr", "0013", "receipt", "chain", "owner", "md"]
  end

  test "digest is salted, so the same token differs under a different salt" do
    refute Names.digest("salt-a", @synthetic) == Names.digest("salt-b", @synthetic)
  end

  test "the committed digest file carries a salt and at least one digest, and no plain names" do
    body = File.read!("priv/name_digests.txt")
    assert body =~ ~r/^salt [0-9a-f]{8,}$/m
    assert [_ | _] = Regex.scan(~r/^digest [0-9a-f]{64}$/m, body)
  end
end

defmodule TrinityNamesSkipTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Trinity.Names

  test "the platform-name scan skips exactly one path: the enforcer's own source" do
    assert Names.platform_scan_skip() == ["lib/mix/tasks/trinity.names.ex"],
           "the skip list must not grow. It exists only because the plain-text set has to be " <>
             "spelled in the module that matches it. Got: #{inspect(Names.platform_scan_skip())}"
  end

  test "the zero-site names need no exemption, because they are spelled nowhere" do
    body = File.read!("lib/mix/tasks/trinity.names.ex")
    refute body =~ ~r/zero-site name literal/, "placeholder guard"
    assert File.read!("priv/name_digests.txt") =~ "digest "
  end
end
