# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.Policy do
  @moduledoc """
  The role each LiveView event needs (slice 136).

  **An event not named here needs `administer`.** The table lists what a lesser role may send, so
  a new event that nobody classified fails closed rather than open; a census test
  (`test/trinity_web/auth/policy_census_test.exs`) reads every `handle_event` clause under
  `lib/trinity_web/live/` and fails on one this table does not name explicitly, so the default is
  a backstop and not the way events get classified.

  The three roles (`TrinityWeb.Auth.Principal`):

    * `view`: reading, filtering, navigating, and conversing. Sending a message can make the agent
      ask for an effect, but asking is not deciding: the effect still waits on an `approve`.
    * `approve`: deciding an approval request, and the decisions that are the same act on another
      object (a skill change, a changed tool definition, a memory proposal).
    * `administer`: everything that changes what Trinity is or what leaves the machine: MCP
      servers, gateways, settings and keys, personas, standing rules, memory edits, tasks, the
      first-run setup, a session's project root.
  """

  @view %{
    TrinityWeb.ActivityLive => ~w(filter session),
    TrinityWeb.MCPLive => ~w(transport view hide),
    TrinityWeb.MemoryLive => ~w(cancel cancel_edit edit new_session pick_persona semantic_search),
    TrinityWeb.PermissionsLive => ~w(cancel new_session),
    TrinityWeb.PersonasLive => ~w(cancel new_session),
    TrinityWeb.ReceiptsLive => ~w(refresh verify),
    TrinityWeb.SearchLive => ~w(cancel new_session search),
    TrinityWeb.SessionLive.Index => ~w(cancel new_session pick_persona),
    TrinityWeb.SessionLive.Show =>
      ~w(cancel cancel_subagent dismiss new_session retry send set_model),
    TrinityWeb.SettingsLive => ~w(cancel new_session),
    TrinityWeb.SkillsLive => ~w(cancel close hide_change new_session show_change view),
    TrinityWeb.TasksLive => ~w(cancel_edit change edit hide seen seen_all suggest view)
  }

  @approve %{
    TrinityWeb.MemoryLive => ~w(apply_proposal reject_proposal),
    TrinityWeb.PermissionsLive =>
      ~w(approval_answer approval_decide approval_pattern drift_accept drift_dismiss),
    TrinityWeb.SessionLive.Show => ~w(approval_answer approval_decide approval_pattern),
    TrinityWeb.SkillsLive => ~w(approve_change reject_change)
  }

  @administer %{
    # Clearing the activity buffer removes what the page shows for everyone.
    TrinityWeb.ActivityLive => ~w(clear),
    TrinityWeb.GatewaysLive => ~w(allow revoke),
    TrinityWeb.MCPLive => ~w(authorize create disable enable reconnect remove),
    TrinityWeb.MemoryLive => ~w(add delete download_model save semantic_delete semantic_pin),
    TrinityWeb.PermissionsLive => ~w(proposal_accept revoke),
    TrinityWeb.PersonasLive => ~w(create memory_rule save),
    TrinityWeb.SessionLive.Show => ~w(set_project_root),
    TrinityWeb.SettingsLive =>
      ~w(add_root pick_root remove_key remove_root save_hotkey save_key toggle_autostart toggle_gateways toggle_muted),
    TrinityWeb.SetupLive =>
      ~w(add_root choose_model confirm_data_dir finish pick_root remove_root),
    TrinityWeb.SkillsLive => ~w(learn reindex set_status),
    TrinityWeb.TasksLive => ~w(remove run_now save toggle)
  }

  @doc "The role `event` needs on `view`; `administer` when the table does not name it."
  @spec event_role(module(), String.t()) :: TrinityWeb.Auth.Principal.role()
  def event_role(view, event) do
    cond do
      event in Map.get(@view, view, []) -> :view
      event in Map.get(@approve, view, []) -> :approve
      true -> :administer
    end
  end

  @doc "Every `{view, event, role}` the table names explicitly, for the census."
  @spec named() :: [{module(), String.t(), TrinityWeb.Auth.Principal.role()}]
  def named do
    for {role, table} <- [view: @view, approve: @approve, administer: @administer],
        {view, events} <- table,
        event <- events,
        do: {view, event, role}
  end
end
