# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Secrets.MigrationTest do
  @moduledoc """
  Slice 135: `Trinity.Secrets.Migration.run/1` on temporary directories (the boot that runs it is
  `Trinity.SecretsBootNodeTest`, AC4). What moves, the modes it leaves, a conflict left in place,
  an operator's configured location left alone, and nothing to do when nothing is there.
  """
  use ExUnit.Case, async: false

  alias Trinity.Secrets.Migration

  setup do
    base = Path.join(System.tmp_dir!(), "s135m-#{System.unique_integer([:positive])}")
    data = Path.join(base, "data")
    secrets = Path.join(base, "secrets")
    File.mkdir_p!(data)
    saved_receipts = Application.get_env(:trinity, :receipts, [])
    saved_auth = Application.get_env(:trinity, :mcp_auth, [])
    # The release defaults: nothing pinned.
    Application.put_env(:trinity, :receipts, Keyword.delete(saved_receipts, :keys_dir))
    Application.put_env(:trinity, :mcp_auth, [])

    on_exit(fn ->
      Application.put_env(:trinity, :receipts, saved_receipts)
      Application.put_env(:trinity, :mcp_auth, saved_auth)
      File.rm_rf!(base)
    end)

    {:ok, data: data, secrets: secrets}
  end

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  test "nothing there, nothing moved", %{data: data, secrets: secrets} do
    assert Migration.run(data_dir: data, secrets_dir: secrets) == nil
  end

  test "keys, the bearer token and the OAuth store move; modes are set; the old places go", %{
    data: data,
    secrets: secrets
  } do
    File.mkdir_p!(Path.join(data, "keys"))
    File.write!(Path.join(data, "keys/receipts-ed25519.key"), "k")
    File.write!(Path.join(data, "keys/registry.json"), "[]")
    File.write!(Path.join(data, "keys/mcp-state.key"), "s")
    File.write!(Path.join(data, "mcp-server-token"), "t")
    File.mkdir_p!(Path.join(data, "secrets/oauth"))
    File.write!(Path.join(data, "secrets/oauth/r.json"), "{}")

    report = Migration.run(data_dir: data, secrets_dir: secrets)

    assert report["to"] == Path.join(secrets, "keys")
    assert report["files"] == ~w(mcp-state.key receipts-ed25519.key registry.json)
    assert report["conflicts"] == []
    assert length(report["moved"]) == 3

    assert File.read!(Path.join(secrets, "keys/receipts-ed25519.key")) == "k"
    assert mode(Path.join(secrets, "keys/receipts-ed25519.key")) == 0o400
    assert mode(Path.join(secrets, "keys/mcp-state.key")) == 0o400
    assert mode(Path.join(secrets, "keys/registry.json")) == 0o600
    assert mode(Path.join(secrets, "mcp-server-token")) == 0o400
    assert mode(Path.join(secrets, "oauth/r.json")) == 0o600
    assert mode(secrets) == 0o700
    assert mode(Path.join(secrets, "keys")) == 0o700

    refute File.exists?(Path.join(data, "keys"))
    refute File.exists?(Path.join(data, "mcp-server-token"))
    refute File.exists?(Path.join(data, "secrets"))
    refute inspect(report) =~ "\"k\""
  end

  test "a file already at the destination is never overwritten; the source stays and is named", %{
    data: data,
    secrets: secrets
  } do
    File.mkdir_p!(Path.join(data, "keys"))
    File.write!(Path.join(data, "keys/registry.json"), "old")
    File.write!(Path.join(data, "keys/device_id"), "d")
    File.mkdir_p!(Path.join(secrets, "keys"))
    File.write!(Path.join(secrets, "keys/registry.json"), "new")

    report = Migration.run(data_dir: data, secrets_dir: secrets)

    assert report["conflicts"] == [Path.join(data, "keys/registry.json")]
    assert report["files"] == ["device_id"]
    assert File.read!(Path.join(secrets, "keys/registry.json")) == "new"
    assert File.read!(Path.join(data, "keys/registry.json")) == "old"
  end

  test "a location the operator configured is the operator's", %{data: data, secrets: secrets} do
    Application.put_env(:trinity, :receipts, keys_dir: Path.join(data, "keys"))
    File.mkdir_p!(Path.join(data, "keys"))
    File.write!(Path.join(data, "keys/receipts-ed25519.key"), "k")

    assert Migration.run(data_dir: data, secrets_dir: secrets) == nil
    assert File.exists?(Path.join(data, "keys/receipts-ed25519.key"))
  end
end
