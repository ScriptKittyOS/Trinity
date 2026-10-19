# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Toolchain do
  @moduledoc """
  The runtime floor Trinity refuses to boot below (slice 137).

  The floor is "OTP 28.5.0.4 or later, or the 27.3.4.15 or 29.0.4 lines": the releases that fix
  CVE-2026-55737, "heap corruption when an invalidly encoded tuple with an arity of 2^31 or larger
  is decoded from Erlang's External Term Format" (OTP-20214, erts). The same releases fix CVEs in
  ssl, public_key, crypto, ssh and stdlib, so erts alone does not say a runtime is at the floor.

  ## What is compared

  `priv/otp_floor.table` holds the three rows of erlang/otp's `otp_versions.table`, verbatim, with
  the commit and SHA-256 they came from. Each row lists every application at its version in that
  release. A runtime is at the floor for its line when erts and every loaded application the row
  names are at or above the row's version. erts comes from `:erlang.system_info(:version)` and the
  applications from `:application.loaded_applications/0`, both of which answer in an assembled
  release, which carries no `OTP_VERSION` file (slice 130, D-130-11). By the time
  `Trinity.Application.start/2` asks, every application Trinity depends on is loaded.

  A major above the last row passes: fixes land forward into later majors. A major below the first
  row refuses: no fixed release exists for it.

  Elixir must be 1.20.x (`~> 1.20.0`), as the shared contract states it for every box release.
  """

  @table Path.join([__DIR__, "..", "..", "priv", "otp_floor.table"]) |> Path.expand()
  @external_resource @table

  @rows (for line <- File.read!(@table) |> String.split("\n"),
             String.starts_with?(line, "OTP-"),
             into: %{} do
           [release, apps] = String.split(line, " : ", parts: 2)
           "OTP-" <> version = release
           major = version |> String.split(".") |> hd() |> String.to_integer()

           versions =
             for entry <- String.split(apps, [" ", "#", ":"], trim: true),
                 [app, vsn] <- [String.split(entry, "-", parts: 2)],
                 into: %{},
                 do: {String.to_atom(app), vsn}

           {major, %{release: version, apps: versions}}
         end)

  @elixir_requirement "~> 1.20.0"

  @type finding :: {atom(), String.t(), String.t()}
  @type reason ::
          {:otp_below_floor, non_neg_integer(), String.t(), [finding()]}
          | {:otp_major_unsupported, non_neg_integer(), String.t()}
          | {:elixir_outside_floor, String.t(), String.t()}

  @doc "The floor rows, by OTP major: the fixing release and every application's version in it."
  @spec floor() :: %{non_neg_integer() => %{release: String.t(), apps: %{atom() => String.t()}}}
  def floor, do: @rows

  @doc "The Elixir requirement every node must meet."
  @spec elixir_requirement() :: String.t()
  def elixir_requirement, do: @elixir_requirement

  @doc "The runtime this node is on: OTP major, erts, Elixir, and every loaded application's version."
  @spec current() :: %{
          otp_release: String.t(),
          erts: String.t(),
          elixir: String.t(),
          apps: %{atom() => String.t()}
        }
  def current do
    %{
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      erts: List.to_string(:erlang.system_info(:version)),
      elixir: System.version(),
      apps:
        Map.new(:application.loaded_applications(), fn {app, _, vsn} -> {app, to_string(vsn)} end)
    }
  end

  @doc """
  Whether a runtime on OTP major `major`, with erts `erts` and the loaded applications `apps`, is at
  the floor. A refusal lists every component below its row's version, erts first.
  """
  @spec check_otp(non_neg_integer(), String.t(), %{atom() => String.t()}) ::
          :ok | {:error, reason()}
  def check_otp(major, erts, apps \\ %{}) when is_integer(major) and is_binary(erts) do
    {first, last} = Enum.min_max(Map.keys(@rows))

    cond do
      major > last ->
        :ok

      major < first ->
        {:error, {:otp_major_unsupported, major, erts}}

      true ->
        compare_row(major, Map.fetch!(@rows, major), [
          {:erts, erts} | apps |> Map.delete(:erts) |> Enum.sort()
        ])
    end
  end

  # Every component the row names that is below the row's version, erts first.
  defp compare_row(major, %{release: release, apps: row}, components) do
    below =
      for {app, got} <- components,
          required = Map.get(row, app),
          required != nil,
          not at_least?(got, required),
          do: {app, got, required}

    if below == [], do: :ok, else: {:error, {:otp_below_floor, major, release, below}}
  end

  @doc "Whether Elixir `version` meets `elixir_requirement/0`."
  @spec check_elixir(String.t()) :: :ok | {:error, reason()}
  def check_elixir(version) when is_binary(version) do
    if Version.match?(version, @elixir_requirement),
      do: :ok,
      else: {:error, {:elixir_outside_floor, version, @elixir_requirement}}
  end

  @doc "Both checks against the running runtime, the OTP floor first."
  @spec check() :: :ok | {:error, reason()}
  def check do
    %{otp_release: major, erts: erts, elixir: elixir, apps: apps} = current()

    with :ok <- check_otp(String.to_integer(major), erts, apps) do
      check_elixir(elixir)
    end
  end

  @doc """
  True when dotted version `a` is at or above `b`, compared as integer lists, so `16.4.0.10` sorts
  above `16.4.0.4` and `16.4` below `16.4.0.1`. A component that is not an integer compares as 0,
  so an unusual version string cannot raise during boot.
  """
  @spec at_least?(String.t(), String.t()) :: boolean()
  def at_least?(a, b), do: parts(a) >= parts(b)

  defp parts(version) do
    version
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, _} -> n
        :error -> 0
      end
    end)
  end
end
