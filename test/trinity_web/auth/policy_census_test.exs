# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.PolicyCensusTest do
  @moduledoc """
  Slice 136: every LiveView event in the tree is classified by `TrinityWeb.Auth.Policy`, and the
  role claims of the four identity provider shapes map as documented (`TrinityWeb.Auth.Claims`).

  The population of events is read from the source: every `handle_event("name"` clause under
  `lib/trinity_web/live/`, single-line or multi-line heads alike, attributed to the module the file
  defines. An event the table does not name would still need `administer` (the default), so a
  miss here is not a hole; it is an event nobody decided about, which this test makes somebody do.
  """
  use ExUnit.Case, async: true

  alias TrinityWeb.Auth.{Claims, Policy}

  defp events_in_tree do
    for path <- Path.wildcard("lib/trinity_web/live/**/*.ex"),
        source = File.read!(path),
        [_, module] <- [Regex.run(~r/defmodule\s+([\w.]+)\s+do/, source)],
        [_, event] <- Regex.scan(~r/def handle_event\(\s*"([a-z_]+)"/, source),
        uniq: true,
        do: {Module.concat([module]), event}
  end

  test "every handle_event in the tree is named by the policy, once" do
    events = events_in_tree()
    assert length(events) > 80, "the census read #{length(events)} events; is the regex right?"

    named = Policy.named()
    named_keys = Enum.map(named, fn {view, event, _role} -> {view, event} end)

    missing = Enum.reject(events, &(&1 in named_keys))
    assert missing == [], "events no role was decided for: #{inspect(missing)}"

    stale = Enum.reject(named_keys, &(&1 in events))
    assert stale == [], "the policy names events that do not exist: #{inspect(stale)}"

    dupes = named_keys -- Enum.uniq(named_keys)
    assert dupes == [], "named under two roles: #{inspect(dupes)}"
  end

  test "the events AC8 names need administer, approvals need approve, an unnamed one administer" do
    assert Policy.event_role(TrinityWeb.MCPLive, "create") == :administer
    assert Policy.event_role(TrinityWeb.GatewaysLive, "allow") == :administer
    assert Policy.event_role(TrinityWeb.SettingsLive, "save_key") == :administer
    assert Policy.event_role(TrinityWeb.PermissionsLive, "approval_decide") == :approve
    assert Policy.event_role(TrinityWeb.SessionLive.Show, "approval_decide") == :approve
    assert Policy.event_role(TrinityWeb.SessionLive.Show, "send") == :view
    assert Policy.event_role(TrinityWeb.MCPLive, "something_new") == :administer
    assert Policy.event_role(Phoenix.LiveDashboard.PageLive, "anything") == :administer
  end

  describe "role claims" do
    test "Keycloak: realm roles and this client's roles" do
      claims = %{
        "realm_access" => %{"roles" => ["offline_access", "trinity:view"]},
        "resource_access" => %{
          "trinity" => %{"roles" => ["administer"]},
          "other-client" => %{"roles" => ["approve"]}
        }
      }

      assert {:ok, [:view, :administer]} = Claims.roles(claims, "trinity")
    end

    test "Entra: app roles in roles" do
      assert {:ok, [:approve]} = Claims.roles(%{"roles" => ["Trinity.Approve"]}, "app-id")
    end

    test "Okta: groups" do
      assert {:ok, [:view, :approve]} =
               Claims.roles(%{"groups" => ["Everyone", "trinity-approve", "trinity-view"]}, "c")
    end

    test "generic roles, as a list or a space-separated string" do
      assert {:ok, [:administer]} = Claims.roles(%{"roles" => "administer"}, nil)
      assert {:ok, [:view, :approve]} = Claims.roles(%{"roles" => "approve view"}, nil)
    end

    test "a named claim is the only one read" do
      claims = %{"roles" => ["administer"], "trinity_roles" => ["view"]}
      assert {:ok, [:view]} = Claims.roles(claims, nil, "trinity_roles")
      assert {:ok, [:approve]} = Claims.roles(%{"a" => %{"b" => ["approve"]}}, nil, "a.b")
    end

    test "no Trinity role is a refusal naming what was read, never an empty list" do
      assert {:error, {:no_trinity_role, read}} = Claims.roles(%{"roles" => ["Sales"]}, "c")
      assert "roles" in read and "groups" in read
      assert {:error, {:no_trinity_role, _}} = Claims.roles(%{}, nil)
    end

    test "an Entra overage of a claim that would be read is a refusal naming it" do
      overage = %{"_claim_names" => %{"groups" => "src1"}, "roles" => ["view"]}
      assert {:error, {:claim_overage, "groups"}} = Claims.roles(overage, "c")
      assert Claims.describe({:claim_overage, "groups"}) =~ "200 groups"

      # Named elsewhere, the overaged claim is not read and so does not matter.
      assert {:ok, [:view]} = Claims.roles(overage, "c", "roles")
    end
  end
end
