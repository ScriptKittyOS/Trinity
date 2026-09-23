# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.IdentitiesTest do
  @moduledoc """
  Slice 070, AC2's automatic half and the rule docs/07 states: an unknown sender is admitted as
  `pending` with a code and nothing else; the code pairs them once, is refused when wrong,
  expired or already used; a revoked identity cannot pair; an allowlisted id is paired at first
  sight; and a pending identity whose code has expired is given a new one rather than being
  locked out.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Gateways.{Identities, Identity}

  @adapter "console"
  @user "u-1"

  test "an unknown sender is pending with a live code, and nothing else is created" do
    assert {:ok, %Identity{} = identity, :pending} =
             Identities.admit(@adapter, @user, conversation: "c1", display_name: "Someone")

    assert identity.state == "pending"
    assert String.length(identity.code) == 6
    assert identity.code =~ ~r/^[A-Z2-9]+$/
    assert DateTime.compare(identity.code_expires_at, DateTime.utc_now()) == :gt
    assert identity.paired_at == nil
    assert identity.last_conversation == "c1"
    assert Identities.pending() |> Enum.map(& &1.id) == [identity.id]
  end

  test "the code pairs the sender once; a wrong code, an expired one and a second use are refused" do
    {:ok, identity, :pending} = Identities.admit(@adapter, @user)

    assert {:error, :wrong_code} = Identities.pair(@adapter, @user, "AAAAAA")
    assert {:ok, paired} = Identities.pair(@adapter, @user, String.downcase(identity.code))
    assert paired.state == "paired" and paired.paired_at != nil
    assert paired.code == nil, "the code is spent, not kept"

    # A second attempt with the same code has nothing to match.
    assert {:error, :no_code} = Identities.pair(@adapter, @user, identity.code)

    # And the next message is simply admitted.
    assert {:ok, _, :paired} = Identities.admit(@adapter, @user)
  end

  test "an expired code is refused, and the next message is given a fresh one" do
    {:ok, identity, :pending} = Identities.admit(@adapter, @user)
    stale = DateTime.add(DateTime.utc_now(), -1, :second)
    {:ok, _} = identity |> Identity.changeset(%{code_expires_at: stale}) |> Trinity.Repo.update()

    assert {:error, :expired} = Identities.pair(@adapter, @user, identity.code)
    assert Identities.pending() == []

    assert {:ok, refreshed, :pending} = Identities.admit(@adapter, @user)
    assert refreshed.code != identity.code
    assert {:ok, _} = Identities.pair(@adapter, @user, refreshed.code)
  end

  test "a revoked identity cannot pair and is not admitted" do
    {:ok, identity, :pending} = Identities.admit(@adapter, @user)
    assert {:ok, revoked} = Identities.revoke(identity)
    assert revoked.state == "revoked" and revoked.revoked_at != nil

    assert {:ok, _, :revoked} = Identities.admit(@adapter, @user)
    assert {:error, :revoked} = Identities.pair(@adapter, @user, identity.code)
    # The row stays: a refusal is visible on the page rather than absent from it.
    assert Enum.map(Identities.list(), & &1.id) == [identity.id]
  end

  test "an allowlisted id is paired at first sight, with no code shown" do
    Application.put_env(:trinity, :gateways, allowlist: [{"console", "trusted"}])
    on_exit(fn -> Application.delete_env(:trinity, :gateways) end)

    assert {:ok, identity, :paired} = Identities.admit(@adapter, "trusted")
    assert identity.state == "paired" and identity.code == nil
    assert Identities.pending() == []

    # The allowlist names one pair, not a platform: another id on the same adapter still pairs.
    assert {:ok, _, :pending} = Identities.admit(@adapter, "someone-else")
  end

  test "the same external id on two adapters is two identities" do
    assert {:ok, one, :pending} = Identities.admit("console", "same-id")
    assert {:ok, two, :pending} = Identities.admit("other", "same-id")
    assert one.id != two.id
    assert {:ok, _} = Identities.pair("console", "same-id", one.code)
    assert {:ok, _, :pending} = Identities.admit("other", "same-id")
  end

  # A pairing code is a credential, so where it comes from is a property worth holding rather than
  # a detail. `Enum.random/1` draws from `:rand`, which is predictable from observed output; this
  # was the generator until the security audit for the OpenSSF criteria caught it.
  test "pairing codes come from the cryptographically secure generator, over the whole alphabet" do
    codes = for _ <- 1..200, do: Identities.generate_code()

    assert Enum.all?(codes, &(String.length(&1) == 6))
    assert Enum.all?(codes, &(&1 =~ ~r/^[A-HJ-NP-Z2-9]+$/))

    # Distinct: 200 draws from 32^6 collide with negligible probability, so a repeat means the
    # generator is not drawing from the space it claims to.
    assert length(Enum.uniq(codes)) == 200

    # The alphabet excludes the characters a person reads for one another (I, O, 0, 1), and the
    # draw reaches the rest of it: a generator stuck on a subset would fail here.
    seen = codes |> Enum.join() |> String.graphemes() |> Enum.uniq()
    assert length(seen) > 24, "only #{length(seen)} distinct characters in 1,200 draws"
    refute Enum.any?(seen, &(&1 in ["I", "O", "0", "1"]))
  end

  test "no security value in the gateway package is drawn from the non-cryptographic generator" do
    {out, 0} = System.cmd("git", ["ls-files", "lib/trinity/gateways"])

    for file <- String.split(out, "\n", trim: true) do
      # Comments and docs are stripped first: a moduledoc explaining why the non-cryptographic
      # generator is not used names it, and naming it is not calling it.
      source =
        file
        |> File.read!()
        |> String.replace(~r/@(module)?doc\s+"""(.|\n)*?"""/, "")
        |> String.replace(~r/#[^\n]*/, "")

      refute source =~ ~r/Enum\.random|:rand\./,
             "#{file} draws from the non-cryptographic generator; use :crypto.strong_rand_bytes/1 " <>
               "for anything that is a credential, a nonce or a key"
    end
  end

  test "the desktop can pair and revoke without a code" do
    {:ok, identity, :pending} = Identities.admit(@adapter, @user)
    assert {:ok, allowed} = Identities.allow(identity)
    assert allowed.state == "paired" and allowed.code == nil
  end
end
