# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TLSTest do
  @moduledoc """
  `Trinity.TLS`'s decision and the options it hands out (ADR-0014). What reaches the wire is
  `test/trinity/tls_clamp_test.exs`'s; this is the module's own arithmetic.
  """

  use ExUnit.Case, async: true

  alias Trinity.TLS

  describe "affected?/2" do
    test "OTP 28 is affected below ssl 11.6.0.6 and fixed from it" do
      # otp_versions.table: OTP-28.5.0.5 ssl-11.6.0.4, OTP-28.5.0.6 ssl-11.6.0.5,
      # OTP-28.5.0.7 ssl-11.6.0.6.
      assert TLS.affected?("28", "11.6.0.4")
      assert TLS.affected?("28", "11.6.0.5")
      refute TLS.affected?("28", "11.6.0.6")
      refute TLS.affected?("28", "11.6.0.10")
      refute TLS.affected?("28", "11.7")
    end

    test "the comparison is numeric, not a string comparison" do
      # As strings, "11.6.0.10" sorts before "11.6.0.6".
      refute TLS.affected?("28", "11.6.0.10")
      assert TLS.affected?("28", "11.6.0")
    end

    test "a major with no recorded fix, or an unreadable version, clamps" do
      assert TLS.affected?("27", "11.2.12.9")
      assert TLS.affected?("29", "11.9")
      assert TLS.affected?("28", "")
      assert TLS.affected?("28", "11.6.0.6-rc1")
    end
  end

  describe "client_config/1" do
    test "a fixed runtime is configured exactly as before" do
      assert TLS.client_config(false) == []
    end

    test "an affected runtime sets the ssl setting, Req's default pool and ReqLLM's pools" do
      config = TLS.client_config(true)
      assert {:ssl, :protocol_version, [:"tlsv1.2"]} in config
      assert {:req, :default_options, [finch: [name: Trinity.TLS.Finch]]} in config

      {:req_llm, :finch, finch} = List.keyfind(config, :req_llm, 0)
      assert finch[:name] == ReqLLM.Finch

      for {_key, pool} <- finch[:pools] do
        assert pool[:conn_opts][:transport_opts][:versions] == [:"tlsv1.2"]
      end
    end
  end

  describe "req_options/1" do
    test "keeps a caller's transport options and the clamp, and lifts the named pool" do
      options = TLS.req_options(cacertfile: "/tmp/ca.pem", versions: [:"tlsv1.3"])
      assert options[:finch] == nil
      transport = options[:connect_options][:transport_opts]
      assert transport[:cacertfile] == "/tmp/ca.pem"

      if TLS.affected?() do
        assert transport[:versions] == [:"tlsv1.2"]
      end
    end

    test "Req refuses connect_options beside the default pool, so the clamp cannot be bypassed quietly" do
      if TLS.affected?() do
        assert_raise ArgumentError, ~r/cannot set both :finch and :connect_options/, fn ->
          Req.get("https://127.0.0.1:1/", connect_options: [timeout: 100], retry: false)
        end
      end
    end
  end
end
