# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.EmbedderConfigTest do
  @moduledoc """
  Slice 133, D2: the decisions `Trinity.Memory.EmbedderConfig.check/4` makes, as a pure function.
  These prove the decisions; the boots in `test/trinity/embedder_boot_node_test.exs` prove they are
  asked, and asked before the node starts (AC5).
  """
  use ExUnit.Case, async: true

  alias Trinity.Memory.EmbedderConfig

  defp models(url), do: [%{id: "e", base_url: url}]
  defp hosted(extra), do: [embedder: :hosted, hosted_model: "e"] ++ extra

  @allow "https://models.internal"

  test "in-process embedders are in_process by construction; declaring another locality is a fault" do
    for e <- [:static, :local, :fake, [:static, :local]], profile <- [:default, :regulated] do
      assert :ok = EmbedderConfig.check(profile, [embedder: e], [], nil)
      assert :ok = EmbedderConfig.check(profile, [embedder: e, locality: :in_process], [], nil)
    end

    assert {:error, {:embedder_locality_mismatch, :static, :external}} =
             EmbedderConfig.check(:default, [embedder: :static, locality: :external], [], nil)
  end

  test "an endpoint with no locality is a fault under both profiles, whatever the address" do
    for url <- ["http://localhost:11434/v1", "http://10.0.0.5/v1", "https://models.internal/v1"],
        profile <- [:default, :regulated] do
      assert {:error, {:embedder_locality_undeclared, :hosted, ^url}} =
               EmbedderConfig.check(profile, hosted([]), models(url), @allow)
    end
  end

  test "in_process for an endpoint, or an unknown locality, is a fault" do
    assert {:error, {:embedder_locality_in_process_with_endpoint, :hosted}} =
             EmbedderConfig.check(
               :default,
               hosted(locality: :in_process),
               models("http://x"),
               nil
             )

    assert {:error, {:embedder_locality_invalid, :hosted, :enclave}} =
             EmbedderConfig.check(:default, hosted(locality: :enclave), models("http://x"), nil)
  end

  test "external needs the opt-in under both profiles; within_boundary does not" do
    url = "https://models.internal/v1"

    for profile <- [:default, :regulated] do
      assert {:error, {:external_not_opted_in, :hosted}} =
               EmbedderConfig.check(profile, hosted(locality: :external), models(url), @allow)

      assert :ok =
               EmbedderConfig.check(
                 profile,
                 hosted(locality: :external, external_opt_in: true),
                 models(url),
                 @allow
               )

      assert :ok =
               EmbedderConfig.check(
                 profile,
                 hosted(locality: :within_boundary),
                 models(url),
                 @allow
               )
    end
  end

  test "under regulated only, the endpoint must be stated and allow-listed" do
    off = models("https://embed.internal/v1")

    assert :ok = EmbedderConfig.check(:default, hosted(locality: :within_boundary), off, nil)

    assert {:error, {:not_allow_listed, :hosted, "https://embed.internal"}} =
             EmbedderConfig.check(:regulated, hosted(locality: :within_boundary), off, @allow)

    assert {:error, {:not_allow_listed, :hosted, _}} =
             EmbedderConfig.check(
               :regulated,
               hosted(locality: :external, external_opt_in: true),
               off,
               @allow
             )

    assert {:error, {:embedder_endpoint_unstated, :hosted}} =
             EmbedderConfig.check(
               :regulated,
               hosted(locality: :within_boundary),
               models(nil),
               @allow
             )
  end
end
