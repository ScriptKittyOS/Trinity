# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.ToolchainTest do
  @moduledoc """
  Slice 137, AC1 and AC4: the floor decision, at every boundary, against the rows checked in at
  `priv/otp_floor.table`. Slice 141: the headless release's floor (OTP 28.5.0.8, the OTP 28 line
  only), which release a node is, and the decoder probe. The boot that applies them is
  `Trinity.ToolchainNodeTest`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trinity.Toolchain

  # erts at each fixing release, and the patch either side.
  @erts [
    {27, "15.2.7.10", "15.2.7.11", "15.2.7.12"},
    {28, "16.4.0.3", "16.4.0.4", "16.4.0.5"},
    {29, "17.0.3", "17.0.4", "17.0.5"}
  ]

  describe "the rows" do
    test "are the three fixing releases, read from the checked-in table" do
      assert %{
               27 => %{release: "27.3.4.15"},
               28 => %{release: "28.5.0.4"},
               29 => %{release: "29.0.4"}
             } =
               Toolchain.floor()

      assert Toolchain.floor() == Toolchain.floor(:desktop)
    end

    test "slice 141: the headless release's floor is one row, OTP-28.5.0.8, from the same table" do
      assert %{28 => %{release: "28.5.0.8", apps: apps}} = Toolchain.floor(:headless)
      assert map_size(Toolchain.floor(:headless)) == 1

      # erts and the applications whose CVEs 28.5.0.8 fixed, read from its row. The fixes are in
      # the applications, and erts-16.4.0.7 can be installed without them, so both are compared.
      assert apps.erts == "16.4.0.7"
      assert apps.ssl == "11.6.0.7"
      assert apps.public_key == "1.20.3.6"
      assert apps.inets == "9.6.2.4"
      assert apps.ssh == "5.5.2.7"
    end

    test "slice 141: every application in the headless row is at or above the desktop row's" do
      desktop = Toolchain.floor(:desktop)[28].apps

      for {app, vsn} <- Toolchain.floor(:headless)[28].apps,
          required = desktop[app],
          required != nil,
          do: assert(Toolchain.at_least?(vsn, required), "#{app} #{vsn} < #{required}")
    end

    test "each names erts and the applications whose CVEs the release fixed" do
      for {major, erts} <- [{27, "15.2.7.11"}, {28, "16.4.0.4"}, {29, "17.0.4"}] do
        apps = Toolchain.floor()[major].apps
        assert apps.erts == erts

        for app <- [:crypto, :public_key, :ssl, :ssh, :stdlib, :kernel],
            do: assert(is_binary(apps[app]), "OTP #{major} row has no #{app}")
      end

      assert Toolchain.floor()[28].apps.ssl == "11.6.0.4"
      assert Toolchain.floor()[28].apps.public_key == "1.20.3.4"
    end

    test "carry their source: the commit and the SHA-256 of the table they were copied from" do
      text = File.read!("priv/otp_floor.table")
      assert text =~ "499d6a4b8bf8e145f33b7b7fc8a6b11de9e7bda2"
      assert text =~ "8990c38937ba7bb91ac206e659ba5f87289a41f3d69f58ad48f1e6dff5fee197"
    end
  end

  describe "AC1: check_otp/3 at each line's boundary" do
    for {major, below, at, above} <- @erts do
      test "OTP #{major}: erts #{below} refuses, #{at} and #{above} pass" do
        major = unquote(major)
        release = Toolchain.floor()[major].release

        assert Toolchain.check_otp(major, unquote(below)) ==
                 {:error,
                  {:otp_below_floor, major, release, [{:erts, unquote(below), unquote(at)}]}}

        assert Toolchain.check_otp(major, unquote(at)) == :ok
        assert Toolchain.check_otp(major, unquote(above)) == :ok
      end
    end

    test "erts at the floor with an application below it refuses, naming the application" do
      apps = %{ssl: "11.6.0.3", crypto: "5.8.3.2", kernel: "10.6.3.3"}

      assert Toolchain.check_otp(28, "16.4.0.4", apps) ==
               {:error, {:otp_below_floor, 28, "28.5.0.4", [{:ssl, "11.6.0.3", "11.6.0.4"}]}}
    end

    test "every component below the floor is listed, erts first" do
      apps = %{stdlib: "7.3", ssl: "11.6.0.3", crypto: "5.8.3.1"}

      assert {:error, {:otp_below_floor, 28, _, [{:erts, "16.4.0.3", _} | rest]}} =
               Toolchain.check_otp(28, "16.4.0.3", apps)

      assert Enum.map(rest, &elem(&1, 0)) == [:crypto, :ssl, :stdlib]
    end

    test "applications the row does not name are not judged" do
      assert Toolchain.check_otp(28, "16.4.0.6", %{
               trinity: "0.1.0",
               elixir: "1.20.4",
               logger: "1.20.4"
             }) ==
               :ok
    end

    test "the pinned runtimes' erts passes: 16.4.0.6 is both 28.5.0.6 and 28.5.0.7" do
      assert Toolchain.check_otp(28, "16.4.0.6") == :ok
    end

    test "a runtime from before the patch line refuses: OTP 28.1.1 is erts 16.1.1" do
      assert {:error, {:otp_below_floor, 28, "28.5.0.4", [{:erts, "16.1.1", "16.4.0.4"}]}} =
               Toolchain.check_otp(28, "16.1.1")
    end

    test "a two-digit patch sorts as a number, not as text; OTP 29.1's erts 17.1 passes" do
      assert Toolchain.check_otp(28, "16.4.0.10") == :ok
      assert Toolchain.check_otp(29, "17.1") == :ok
    end

    test "a shorter version is below a longer one with the same prefix" do
      assert {:error, _} = Toolchain.check_otp(28, "16.4")
      assert {:error, _} = Toolchain.check_otp(28, "16.4.0")
    end

    test "an unusual component does not raise" do
      assert Toolchain.at_least?("16.4.0.4-rc1", "16.4.0.4") == true
      assert Toolchain.at_least?("x", "1") == false
    end

    test "majors below the first row refuse; majors above the last pass" do
      assert Toolchain.check_otp(26, "14.2.5.12") ==
               {:error, {:otp_major_unsupported, 26, "14.2.5.12"}}

      assert Toolchain.check_otp(30, "18.0") == :ok
    end

    property "agrees with a reference comparison over generated erts versions" do
      check all(
              major <- member_of([27, 28, 29]),
              erts <- list_of(integer(0..40), min_length: 1, max_length: 5)
            ) do
        version = Enum.join(erts, ".")

        floor =
          Toolchain.floor()[major].apps.erts
          |> String.split(".")
          |> Enum.map(&String.to_integer/1)

        want = if erts >= floor, do: :ok, else: :error

        got =
          case Toolchain.check_otp(major, version) do
            :ok -> :ok
            {:error, {:otp_below_floor, ^major, _, [{:erts, ^version, _}]}} -> :error
          end

        assert got == want, "#{major} #{version}"
      end
    end
  end

  describe "slice 141: check_otp/4 for the headless release" do
    # The runtimes measured on 2026-10-20 (`erlang:system_info(version)` and `otp_versions.table`).
    @r28506 %{ssl: "11.6.0.5", public_key: "1.20.3.4", inets: "9.6.2.3", ssh: "5.5.2.5"}
    @r28507 %{ssl: "11.6.0.6", public_key: "1.20.3.5", inets: "9.6.2.3", ssh: "5.5.2.6"}
    @r28508 %{ssl: "11.6.0.7", public_key: "1.20.3.6", inets: "9.6.2.4", ssh: "5.5.2.7"}

    test "28.5.0.8 passes; 28.5.0.7 refuses, naming erts and every application below the row" do
      assert Toolchain.check_otp(28, "16.4.0.7", @r28508, :headless) == :ok

      assert Toolchain.check_otp(28, "16.4.0.6", @r28507, :headless) ==
               {:error,
                {:otp_below_floor, 28, "28.5.0.8",
                 [
                   {:erts, "16.4.0.6", "16.4.0.7"},
                   {:inets, "9.6.2.3", "9.6.2.4"},
                   {:public_key, "1.20.3.5", "1.20.3.6"},
                   {:ssh, "5.5.2.6", "5.5.2.7"},
                   {:ssl, "11.6.0.6", "11.6.0.7"}
                 ]}}
    end

    test "erts at the floor with ssl below it refuses, naming ssl" do
      assert Toolchain.check_otp(28, "16.4.0.7", %{@r28508 | ssl: "11.6.0.6"}, :headless) ==
               {:error, {:otp_below_floor, 28, "28.5.0.8", [{:ssl, "11.6.0.6", "11.6.0.7"}]}}
    end

    test "the desktop floor still passes 28.5.0.6, which the headless floor refuses" do
      assert Toolchain.check_otp(28, "16.4.0.6", @r28506) == :ok
      assert Toolchain.check_otp(28, "16.4.0.6", @r28506, :desktop) == :ok

      assert {:error, {:otp_below_floor, 28, "28.5.0.8", _}} =
               Toolchain.check_otp(28, "16.4.0.6", @r28506, :headless)
    end

    test "every line but OTP 28 refuses, above it as well as below" do
      for {major, erts} <- [{27, "15.2.7.11"}, {29, "17.0.4"}, {29, "17.1"}, {30, "18.0"}],
          do:
            assert(
              Toolchain.check_otp(major, erts, %{}, :headless) ==
                {:error, {:otp_major_unsupported, major, erts}}
            )
    end
  end

  describe "slice 141: kind/1, which floor a node is held to" do
    test "the headless release, by its release name or by its mode, is :headless" do
      assert Toolchain.kind(%{"RELEASE_NAME" => "headless"}) == :headless
      assert Toolchain.kind(%{"TRINITY_MODE" => "headless"}) == :headless

      assert Toolchain.kind(%{"RELEASE_NAME" => "desktop", "TRINITY_MODE" => "headless"}) ==
               :headless

      assert Toolchain.kind(%{"RELEASE_NAME" => "headless", "TRINITY_MODE" => "desktop"}) ==
               :headless
    end

    test "anything else is :desktop" do
      assert Toolchain.kind(%{}) == :desktop
      assert Toolchain.kind(%{"RELEASE_NAME" => "desktop"}) == :desktop
      assert Toolchain.kind(%{"TRINITY_MODE" => "Headless"}) == :desktop
    end
  end

  describe "slice 141: check_decoder/1, the CVE-2026-55737 behaviour" do
    test "this runtime refuses a tuple one element over erts's limit and decodes the control" do
      assert Toolchain.check_decoder() == :ok
    end

    test "a decoder that builds the oversize tuple is refused, naming its arity" do
      # A fixed runtime cannot build a tuple that large at all (`erlang:make_tuple/2` is held to
      # the same limit), so the stand-in returns a term: accepting is answering without raising.
      accepts = fn _bin -> {:decoded} end

      assert Toolchain.check_decoder(accepts) ==
               {:error, {:decoder_accepts_oversize_tuple, 16_777_216}}
    end

    test "a decoder that refuses everything fails the control, so a refusal is not read as a fix" do
      refuses = fn _ -> :erlang.error(:badarg) end
      assert Toolchain.check_decoder(refuses) == {:error, {:decoder_control_failed, 256}}
    end

    test "a decoder that fails another way is a refusal, not a hang and not a pass" do
      crashes = fn _ -> exit(:boom) end
      assert Toolchain.check_decoder(crashes) == {:error, {:decoder_probe_failed, :boom}}
    end

    test "the probe is the encoding the fix refuses: LARGE_TUPLE_EXT with arity 2^24" do
      <<131, 105, arity::32, rest::binary>> = Toolchain.decoder_probe()
      assert arity == 16_777_216
      assert byte_size(rest) == arity
      assert rest == :binary.copy(<<106>>, arity)
    end
  end

  describe "AC4: check_elixir/1" do
    test "1.20.x passes; 1.19.5, a 1.20 release candidate and 1.21.0 refuse" do
      assert Toolchain.check_elixir("1.20.0") == :ok
      assert Toolchain.check_elixir("1.20.4") == :ok

      for v <- ["1.19.5", "1.20.0-rc.1", "1.21.0"],
          do:
            assert(Toolchain.check_elixir(v) == {:error, {:elixir_outside_floor, v, "~> 1.20.0"}})
    end
  end

  describe "the runtime this suite is on" do
    test "current/0 reads the running VM, and check/0 passes on the pin" do
      %{otp_release: release, erts: erts, elixir: elixir, apps: apps} = Toolchain.current()
      assert release == List.to_string(:erlang.system_info(:otp_release))
      assert erts == List.to_string(:erlang.system_info(:version))
      assert elixir == System.version()
      assert apps[:ssl] == to_string(Application.spec(:ssl, :vsn))
      assert Toolchain.check() == :ok
    end
  end
end
