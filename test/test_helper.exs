# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# docs/03: the default run excludes :live (real providers, opt-in with `mix test --only live`
# and TRINITY_LIVE=1) and :desktop (needs the Tauri shell). Slice 011 made this explicit; until
# then a :live test would have run in the default suite and been refused by the network guard.
ExUnit.start(exclude: [:live, :desktop])
Ecto.Adapters.SQL.Sandbox.mode(Trinity.Repo, :manual)

# Slice 011: the Mox mock the registry's :mock provider points at.
Mox.defmock(Trinity.LLM.ProviderMock, for: Trinity.LLM.Provider)
