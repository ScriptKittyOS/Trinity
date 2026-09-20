# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# docs/03: the default run excludes :live (real providers, opt-in with `mix test --only live`
# and TRINITY_LIVE=1) and :desktop (needs the Tauri shell). Slice 011 made this explicit; until
# then a :live test would have run in the default suite and been refused by the network guard.
ExUnit.start(exclude: [:live, :desktop])
Ecto.Adapters.SQL.Sandbox.mode(Trinity.Repo, :manual)

# Slice 011: the Mox mock the registry's :mock provider points at.
Mox.defmock(Trinity.LLM.ProviderMock, for: Trinity.LLM.Provider)
# Slice 020: a tool whose execute/2 a test can forbid (AC6), and a policy whose decide/3 a
# test can count (AC7).
Mox.defmock(Trinity.Tools.ToolMock, for: Trinity.Tools.Tool)
Mox.defmock(Trinity.Permissions.PolicyMock, for: Trinity.Permissions.Policy)
