# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.KeyCustodyKeysDirTest do
  @moduledoc """
  SCR-815: a keys directory that cannot be created is an error, not a raise.

  `Trinity.Receipts.Supervisor` fails open for every profile that is not `:regulated` — it logs,
  sets `Trinity.Receipts.Alarm`, and lets the tree start with every effect denied until a signer
  returns. It does that on an **error tuple** from `KeyCustody.boot!/1`.

  Both ways of resolving the keys directory create it with the raising `File` functions:
  `KeyCustody.keys_dir/0` calls `File.mkdir_p!/1` on a configured path, and
  `Trinity.Paths.keys_dir/0` calls `File.mkdir_p!/1` and `File.chmod!/2` on the default one. A raise
  is not an error tuple, so it never reaches the code that decides to fail open, and the boot goes
  down **whatever the profile** — measured from a spawned `:default` boot as
  `%File.Error{reason: :enotdir}` out of `failed_to_start_child, Trinity.Receipts.Supervisor`.

  The shape is ordinary: a regular file where the keys directory belongs, left by a sync client, a
  restore, or a packaging mistake.

  **`async: false`, and not out of politeness.** `boot!/1` writes its answer to `:persistent_term`
  on both paths, including `{:unavailable, reason}` on failure, so an async version of this poisons
  the signer for the rest of the run. The real signer is restored in `on_exit`.
  """
  use ExUnit.Case, async: false

  alias Trinity.Receipts.KeyCustody

  setup do
    original = Application.get_env(:trinity, :receipts, [])
    path = Path.join(System.tmp_dir!(), "keys-dir-as-file-#{System.unique_integer([:positive])}")
    File.write!(path, "a file where the keys directory should be")

    on_exit(fn ->
      Application.put_env(:trinity, :receipts, original)
      {:ok, _} = KeyCustody.boot!()
      File.rm(path)
    end)

    Application.put_env(:trinity, :receipts, Keyword.put(original, :keys_dir, path))
    {:ok, path: path}
  end

  test "a keys directory that is a regular file is reported, not raised" do
    assert {:error, {:keys_dir, :enotdir}} = KeyCustody.boot!()
  end

  test "the failure is recorded as unavailable, so the chain denies every effect" do
    {:error, reason} = KeyCustody.boot!()
    assert {:unavailable, ^reason} = KeyCustody.selected()
  end
end
