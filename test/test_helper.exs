# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# docs/03: the default run excludes :live (real providers, opt-in with `mix test --only live`
# and TRINITY_LIVE=1) and :desktop (needs the Tauri shell). Slice 011 made this explicit; until
# then a :live test would have run in the default suite and been refused by the network guard.
# Slice 023: :eval (the compaction eval harness, and the suites later slices add) is opt-in too.
# Slice 003: :fips (tests that need FIPS mode on) runs only where the leg declares itself with
# TRINITY_FIPS_LEG=1; excluded by tag elsewhere, never skipped. test/fips/mode_test.exs runs
# everywhere and is what makes a leg that failed to enter the mode red rather than quiet.
# Slice 032: :local_model (the real embedder through the serving) runs where
# TRINITY_LOCAL_MODEL_CACHE names a cache that already holds all-MiniLM-L6-v2 (no download,
# no network: a missing model is a failure there, not a skip); excluded by tag elsewhere.
fips_leg? = System.get_env("TRINITY_FIPS_LEG") == "1"
local_model? = System.get_env("TRINITY_LOCAL_MODEL_CACHE") not in [nil, ""]

ExUnit.start(
  exclude:
    [:live, :desktop, :eval] ++
      if(fips_leg?, do: [], else: [:fips]) ++ if(local_model?, do: [], else: [:local_model])
)

# Slice 024's boot receipt is written by a transient Task after the tree starts; once the
# receipts pool is in manual mode that write can no longer check a connection out, and the
# boot-receipt tests fail with an OwnershipError (postgres job, run 35603385277, at slice
# 032). Wait for the Task to finish, either way, before the mode flips: bounded, and a Task
# that is gone has either written or logged its reason.
boot_task = fn ->
  Trinity.Supervisor
  |> Supervisor.which_children()
  |> Enum.find_value(fn
    {Trinity.Effects.Boot, pid, _, _} when is_pid(pid) -> pid
    _ -> nil
  end)
end

Enum.find(1..200, fn _ ->
  case boot_task.() do
    nil -> true
    _pid -> Process.sleep(50) && false
  end
end)

Ecto.Adapters.SQL.Sandbox.mode(Trinity.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(Trinity.Repo.Receipts, :manual)

# Slice 011: the Mox mock the registry's :mock provider points at.
Mox.defmock(Trinity.LLM.ProviderMock, for: Trinity.LLM.Provider)
# Slice 020: a tool whose execute/2 a test can forbid (AC6), and a policy whose decide/3 a
# test can count (AC7).
Mox.defmock(Trinity.Tools.ToolMock, for: Trinity.Tools.Tool)
Mox.defmock(Trinity.Permissions.PolicyMock, for: Trinity.Permissions.Policy)
