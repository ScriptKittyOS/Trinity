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
# Slice 133: :static_weights (the static embedder's real weights and its parity fixtures) runs
# where TRINITY_STATIC_MODEL_DIR names the directory holding them; excluded by tag elsewhere,
# and where the variable is set a missing file is a failure, never a skip (the owner's rule,
# 2026-10-07). No weights are in the tree before legal review (slice 133 NOTES, D7).
# Slice 134: :tier3_model (the Tier 3 tokenizer's parity with the reference, over the GGUF and
# the fixtures in the model cache) runs where TRINITY_TIER3_MODEL_DIR names that directory, and
# :signing_tools (the import path's signature cases, through the real cosign and model_signing)
# where TRINITY_COSIGN and TRINITY_MODEL_SIGNING name the two programs; excluded by tag
# elsewhere, and where set, a missing file is a failure, never a skip.
# :postgres (EXPLAIN plans and the per-space HNSW indexes) runs only on the Postgres adapter.
# `Trinity.ExcludedCounter` prints, after the summary, how many each of these tags excluded.
fips_leg? = System.get_env("TRINITY_FIPS_LEG") == "1"
local_model? = System.get_env("TRINITY_LOCAL_MODEL_CACHE") not in [nil, ""]
static_weights? = System.get_env("TRINITY_STATIC_MODEL_DIR") not in [nil, ""]
tier3_model? = System.get_env("TRINITY_TIER3_MODEL_DIR") not in [nil, ""]

signing_tools? =
  System.get_env("TRINITY_COSIGN") not in [nil, ""] and
    System.get_env("TRINITY_MODEL_SIGNING") not in [nil, ""]

postgres? = Application.get_env(:trinity, :db_adapter) == Ecto.Adapters.Postgres

ExUnit.start(
  exclude:
    [:live, :desktop, :eval] ++
      if(fips_leg?, do: [], else: [:fips]) ++
      if(local_model?, do: [], else: [:local_model]) ++
      if(static_weights?, do: [], else: [:static_weights]) ++
      if(tier3_model?, do: [], else: [:tier3_model]) ++
      if(signing_tools?, do: [], else: [:signing_tools]) ++
      if(postgres?, do: [], else: [:postgres]),
  formatters: [ExUnit.CLIFormatter, Trinity.ExcludedCounter]
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
