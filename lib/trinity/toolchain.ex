# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Toolchain do
  @moduledoc """
  The runtime floor Trinity refuses to boot below (slice 137), and the headless release's
  stricter one (slice 141).

  ## Two floors

  **Every node** is held to "OTP 28.5.0.4 or later, or the 27.3.4.15 or 29.0.4 lines": the releases
  that fix CVE-2026-55737, "heap corruption when an invalidly encoded tuple with an arity of 2^31 or
  larger is decoded from Erlang's External Term Format" (OTP-20214, erts). The same releases fix CVEs
  in ssl, public_key, crypto, ssh and stdlib, so erts alone does not say a runtime is at the floor.
  The desktop is held to this one: its runtime is the one Burrito can fetch for every target
  (ADR-0005, ADR-0014).

  **The headless release** (`kind/1`), the one deployed as a server, is held to OTP 28.5.0.8 on the
  OTP 28 line, and refuses every other line, above as well as below. 28.5.0.8 fixes CVE-2026-94200
  and CVE-2026-105236 in ssl (a TLS 1.3 client's ticket store; a session resumed under another SNI
  name), CVE-2026-42789 in public_key (a v1 or v2 certificate accepted as a CA) and CVE-2026-48856
  in inets (credentials sent on to a cross-origin redirect). Those fixes are in the applications;
  erts-16.4.0.7, whose own change is a trace fix, can be installed without them (erlang.org: it
  "can be applied independently of other applications on a full OTP 28 installation"), so here too
  erts alone does not say a runtime is at the floor.

  ## What is compared

  `priv/otp_floor.table` holds the four rows of erlang/otp's `otp_versions.table`, verbatim, with
  the commit and SHA-256 they came from. Each row lists every application at its version in that
  release. A runtime is at a floor for its line when erts and every loaded application the row
  names are at or above the row's version. erts comes from `:erlang.system_info(:version)` and the
  applications from `:application.loaded_applications/0`, both of which answer in an assembled
  release, which carries no `OTP_VERSION` file (slice 130, D-130-11). By the time
  `Trinity.Application.start/2` asks, every application Trinity depends on is loaded.

  Under the every-node floor, a major above the last row passes (fixes land forward into later
  majors) and a major below the first row refuses (no fixed release exists for it).

  ## The decoder, asked directly

  A version is what a runtime says it is. `check_decoder/1` asks the decoder itself: it decodes a
  tuple one element over erts's limit (`ERTS_MAX_TUPLE_SIZE`, 2^24 - 1), which the CVE-2026-55737
  fix refuses in `decoded_size()` (erts/emulator/beam/external.c, OTP-28.5.0.4) and an unfixed
  runtime builds, and a small tuple of the same encoding, which every runtime decodes. Measured on
  2026-10-20: OTP 28.1.1 builds the 16,777,216-element tuple (82 ms); 28.5.0.5 to 28.5.0.8 and 29.1
  refuse it in about 20 microseconds.

  ## The fault seam

  `config :trinity, :decoder_probe_fault, true` makes `check/1` probe a decoder that accepts every
  input, so a boot test can show the probe is asked at boot on a runtime whose decoder is fixed. Like
  `Trinity.Crypto.Preflight`'s seam, it can only turn a pass into a refusal, never the other way.

  Elixir must be 1.20.x (`~> 1.20.0`) on every node.
  """

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @table Path.join([__DIR__, "..", "..", "priv", "otp_floor.table"]) |> Path.expand()
  @external_resource @table

  # Every row in the table, by release.
  @releases (for line <- File.read!(@table) |> String.split("\n"),
                 String.starts_with?(line, "OTP-"),
                 into: %{} do
               [release, apps] = String.split(line, " : ", parts: 2)
               "OTP-" <> version = release

               versions =
                 for entry <- String.split(apps, [" ", "#", ":"], trim: true),
                     [app, vsn] <- [String.split(entry, "-", parts: 2)],
                     into: %{},
                     do: {String.to_atom(app), vsn}

               {version, %{release: version, apps: versions}}
             end)

  # The releases each floor is made of, and what it says of a major with no row: the every-node
  # floor passes a major above its last row; the headless floor refuses any major it has no row for.
  @floors %{
    desktop: {["27.3.4.15", "28.5.0.4", "29.0.4"], :pass_above},
    headless: {["28.5.0.8"], :refuse_others}
  }

  @rows (for {kind, {releases, _}} <- @floors, into: %{} do
           {kind,
            Map.new(releases, fn release ->
              major = release |> String.split(".") |> hd() |> String.to_integer()
              {major, Map.fetch!(@releases, release)}
            end)}
         end)

  # LARGE_TUPLE_EXT (105) with arity 2^24, one over ERTS_MAX_TUPLE_SIZE, then that many NIL_EXT
  # (106); and the control, the same encoding at arity 256.
  @oversize 16_777_216
  @control 256

  @elixir_requirement "~> 1.20.0"

  @type finding :: {atom(), String.t(), String.t()}
  @type kind :: :desktop | :headless
  @type reason ::
          {:otp_below_floor, non_neg_integer(), String.t(), [finding()]}
          | {:otp_major_unsupported, non_neg_integer(), String.t()}
          | {:elixir_outside_floor, String.t(), String.t()}
          | {:decoder_accepts_oversize_tuple, pos_integer()}
          | {:decoder_control_failed, pos_integer()}
          | {:decoder_probe_failed, term()}

  @doc """
  A floor's rows, by OTP major: the fixing release and every application's version in it. The
  every-node floor (`:desktop`) by default.
  """
  @spec floor(kind()) ::
          %{non_neg_integer() => %{release: String.t(), apps: %{atom() => String.t()}}}
  def floor(kind \\ :desktop) when is_map_key(@rows, kind), do: Map.fetch!(@rows, kind)

  @doc """
  The floor a node is held to: `:headless` when the process is the headless release, by its release
  name (`RELEASE_NAME`, which the release's own script exports) or by the mode it was started in
  (`TRINITY_MODE`, which the image sets); `:desktop` otherwise. Either signal is enough, so a
  headless node is never held to the weaker floor because one of the two was left unset.
  """
  @spec kind(%{String.t() => String.t()}) :: kind()
  def kind(env) when is_map(env) do
    if env["RELEASE_NAME"] == "headless" or env["TRINITY_MODE"] == "headless",
      do: :headless,
      else: :desktop
  end

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
  floor `kind`. A refusal lists every component below its row's version, erts first.
  """
  @spec check_otp(non_neg_integer(), String.t(), %{atom() => String.t()}, kind()) ::
          :ok | {:error, reason()}
  def check_otp(major, erts, apps \\ %{}, kind \\ :desktop)
      when is_integer(major) and is_binary(erts) and is_map_key(@floors, kind) do
    rows = Map.fetch!(@rows, kind)
    {_, others} = Map.fetch!(@floors, kind)

    cond do
      Map.has_key?(rows, major) ->
        compare_row(major, Map.fetch!(rows, major), [
          {:erts, erts} | apps |> Map.delete(:erts) |> Enum.sort()
        ])

      others == :pass_above and major > rows |> Map.keys() |> Enum.max() ->
        :ok

      true ->
        {:error, {:otp_major_unsupported, major, erts}}
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

  @doc "The probe `check_decoder/1` decodes: a tuple one element over erts's limit, encoded."
  @spec decoder_probe() :: binary()
  def decoder_probe, do: large_tuple(@oversize)

  @doc """
  Whether the decoder refuses a tuple one element over erts's limit, and still decodes a small one
  of the same encoding, so that a decoder refusing everything is not read as fixed. `decode` is
  `:erlang.binary_to_term/1` except where a test plants another.

  It runs in a process of its own, so the 16 MiB probe, and the 128 MiB tuple an unfixed runtime
  builds from it, are freed when the answer comes back and are never on the booting process's heap.
  A probe that fails in any other way is a refusal too, never a wait and never a pass.
  """
  @spec check_decoder((binary() -> term())) :: :ok | {:error, reason()}
  def check_decoder(decode \\ erlang_decoder()) when is_function(decode, 1) do
    {_pid, ref} = spawn_monitor(fn -> exit({:answer, decoder_answer(decode)}) end)

    receive do
      {:DOWN, ^ref, :process, _, {:answer, answer}} -> answer
      {:DOWN, ^ref, :process, _, reason} -> {:error, {:decoder_probe_failed, reason}}
    end
  end

  defp decoder_answer(decode) do
    cond do
      not refuses?(decode, large_tuple(@oversize)) ->
        {:error, {:decoder_accepts_oversize_tuple, @oversize}}

      not control_decodes?(decode) ->
        {:error, {:decoder_control_failed, @control}}

      true ->
        :ok
    end
  end

  defp refuses?(decode, bin) do
    _ = decode.(bin)
    false
  rescue
    ArgumentError -> true
  end

  defp control_decodes?(decode) do
    term = decode.(large_tuple(@control))
    is_tuple(term) and tuple_size(term) == @control
  rescue
    ArgumentError -> false
  end

  # sobelow_skip reason: Misc.BinToTerm: the decoder is only ever handed `large_tuple/1` of two
  # constant arities, bytes this module builds; nothing from outside reaches it. Decoding them is
  # the check.
  @sobelow_skip ["Misc.BinToTerm"]
  defp erlang_decoder, do: &:erlang.binary_to_term/1

  defp large_tuple(arity), do: <<131, 105, arity::32, :binary.copy(<<106>>, arity)::binary>>

  @doc """
  Every check against the running runtime, for the floor `kind/1` reads from the process's
  environment: the OTP floor, then the decoder, then Elixir.
  """
  @spec check() :: :ok | {:error, reason()}
  def check, do: check(kind(System.get_env()))

  @doc "Every check against the running runtime, for floor `kind`."
  @spec check(kind()) :: :ok | {:error, reason()}
  def check(kind) do
    %{otp_release: major, erts: erts, elixir: elixir, apps: apps} = current()

    decoder =
      if Application.get_env(:trinity, :decoder_probe_fault) == true,
        do: fn _ -> :planted end,
        else: erlang_decoder()

    with :ok <- check_otp(String.to_integer(major), erts, apps, kind),
         :ok <- check_decoder(decoder) do
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
