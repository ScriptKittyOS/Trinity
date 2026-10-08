# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TLSClampTest do
  @moduledoc """
  The desktop's TLS 1.2 clamp (owner decision D2, ADR-0014): on an OTP that carries
  CVE-2026-89422, a TLS 1.3 client that accepts a `pre_shared_key` it never offered skips the
  server's certificate, so no BEAM client in the release may offer TLS 1.3 there.

  Three parts, so that "every client" is a population read from the release and not a list
  someone remembered:

  1. **The census.** Every module in the release's applications that calls `ssl:connect`, read
     from the BEAM import tables, and every module outside Mint that opens a Mint connection.
     Each is named here with the layer that clamps it. A new one fails until it is named; a
     named one that is no longer found fails as stale.
  2. **The layers are in force.** The `ssl` application's `protocol_version`, every running
     Finch instance's pools, and the Finch pool Req's defaults resolve to.
  3. **The probe.** A loopback listener reads the ClientHello each client path actually sends
     and records the protocol versions it offers. That is the property itself, observed on the
     wire, rather than a reading of configuration.

  The oracle for "this runtime carries the CVE" is the runtime's own `OTP_VERSION` file, read
  here independently of `Trinity.TLS`, so the test does not grade the module by its own
  answer. An assembled release has no such file (slice 130 NOTES, D-130-11); `mix test` runs on
  an OTP install, which does.
  """

  use ExUnit.Case, async: false

  # The clients fail when the probe hangs up after their ClientHello, and some log it.
  @moduletag :capture_log

  # The first OTP 28 patch with the fix (GHSA-rgxr-4g4w-j875; otp_versions.table, OTP-28.5.0.7).
  @fixed_28 [28, 5, 0, 7]
  @tls12 0x0303
  @tls13 0x0304
  @clamp [:"tlsv1.2"]

  # Every module outside the `ssl` application that calls ssl:connect/2,3,4, and the layer that
  # keeps it off TLS 1.3. `:ssl_setting` is the `ssl` application's `protocol_version`, which an
  # explicit `versions` option overrides; none of these passes one (D-130-12). `:finch_pool` is
  # Mint, which always passes `versions` itself, so only a Finch pool's transport options reach it.
  @openers %{
    :http_transport => :ssl_setting,
    :httpc_handler => :ssl_setting,
    Postgrex.Protocol => :ssl_setting,
    WebSockex.Conn => :ssl_setting,
    Mint.Core.Transport.SSL => :finch_pool
  }

  # Every module outside Mint that opens a Mint connection. Finch's two take their transport
  # options from the pool. ReqLLM's duplex session passes none and so offers TLS 1.3; it is the
  # transport of `ReqLLM.Bedrock.NovaSonic`, and the reachability test below holds that no
  # Trinity module reaches it.
  @mint_callers %{
    Finch.HTTP1.Conn => :finch_pool,
    Finch.HTTP2.Pool => :finch_pool,
    ReqLLM.Streaming.HTTP2DuplexSession => :unreachable
  }

  @mint_connect [{Mint.HTTP, :connect}, {Mint.HTTP1, :connect}, {Mint.HTTP2, :connect}]

  # Every module outside the `ssl` application whose code names TLS 1.3 (in its atom table or its
  # literals). An explicit `versions` option overrides the `ssl` setting, so a client that names
  # TLS 1.3 is a client the first layer does not reach; this is how one would show up.
  @name_tls13 %{
    # Its default `versions`, which a Finch pool's transport options replace.
    Mint.Core.Transport.SSL => :finch_pool,
    # Configures TLS listeners (`Plug.SSL.configure/1`), a server; Trinity's endpoint has none.
    Plug.SSL => :server,
    # A Mix task that generates release files; a release carries no Mix to run it.
    Mix.Tasks.Phx.Gen.Release => :mix_task
  }

  # Req's own pool, started by Req with its default pool options. With the clamp in force no
  # request reaches it: Req's defaults name the clamped pool, and a caller that passes
  # `connect_options` gets a pool of its own (and must take them from `Trinity.TLS`).
  @unclamped_finch [Req.Finch]

  describe "the census, from the release's BEAM files" do
    test "every module that calls ssl:connect is named, with the layer that clamps it" do
      found =
        callers_of(fn {m, f, a} -> m == :ssl and f == :connect and a in 2..4 end, &(&1 != :ssl))

      assert_census(found, @openers, "call ssl:connect")
    end

    test "every module outside Mint that opens a Mint connection is named" do
      found = callers_of(fn {m, f, _} -> {m, f} in @mint_connect end, &(&1 != :mint))
      assert_census(found, @mint_callers, "open a Mint connection")
    end

    test "every module that names TLS 1.3 is named, with why it cannot offer it to a server" do
      found =
        for {app, mod, _imports} <- modules(),
            app != :ssl,
            String.contains?(code_names(mod), "tlsv1.3"),
            uniq: true,
            do: mod

      assert_census(found, @name_tls13, "name TLS 1.3")
    end

    test "no Trinity module reaches the one Mint caller that takes no transport options" do
      unreachable = for {mod, :unreachable} <- @mint_callers, do: mod
      reaching = transitive_callers(MapSet.new(unreachable))
      ours = for {app, mod} <- reaching, app == :trinity, do: mod

      assert ours == [],
             "Trinity reaches a client that offers TLS 1.3 regardless of the clamp: " <>
               inspect(ours)
    end
  end

  describe "the layers, in this runtime" do
    test "the ssl application's protocol_version is the clamp exactly when the runtime is affected" do
      setting = Application.get_env(:ssl, :protocol_version)

      if affected?() do
        assert setting == @clamp,
               "OTP #{otp_version_string()} carries CVE-2026-89422 and ssl's protocol_version is " <>
                 inspect(setting)
      else
        refute setting == @clamp, "OTP #{otp_version_string()} is fixed and still clamped"
      end
    end

    test "every running Finch instance's pools carry the clamp when the runtime is affected" do
      instances = finch_instances()
      assert instances != [], "no running Finch instance found; the census found nothing"

      if affected?() do
        unclamped =
          for {name, config} <- instances,
              name not in @unclamped_finch,
              pool <- [config.default_pool_config | Map.values(config.pools)],
              versions(pool) != @clamp,
              do: {name, versions(pool)}

        assert unclamped == [], "Finch pools that can offer TLS 1.3: #{inspect(unclamped)}"
      end
    end

    test "Req's default request resolves to a clamped Finch instance when the runtime is affected" do
      if affected?() do
        name = Req.new() |> Map.fetch!(:options) |> Map.get(:finch, []) |> Keyword.get(:name)
        assert name, "Req's default options name no Finch instance, so Req.Finch serves them"
        assert {^name, config} = List.keyfind(finch_instances(), name, 0)
        assert versions(config.default_pool_config) == @clamp
      end
    end
  end

  describe "the probe: what each client offers on the wire" do
    test "Req, the client every Trinity call site uses" do
      assert_offer(fn port -> Req.get("https://127.0.0.1:#{port}/", retry: false) end)
    end

    test "ReqLLM, a request without streaming" do
      assert_offer(fn port ->
        ReqLLM.generate_text("openai:gpt-4o-mini", "probe",
          base_url: "https://127.0.0.1:#{port}/v1",
          api_key: "probe",
          max_retries: 0
        )
      end)
    end

    test "ReqLLM, a streaming request (its own Finch pool)" do
      assert_offer(fn port ->
        with {:ok, response} <-
               ReqLLM.stream_text("openai:gpt-4o-mini", "probe",
                 base_url: "https://127.0.0.1:#{port}/v1",
                 api_key: "probe",
                 max_retries: 0
               ) do
          response |> ReqLLM.StreamResponse.tokens() |> Enum.take(1)
        end
      end)
    end

    test ":httpc, the client Bumblebee and Tokenizers download through" do
      {:ok, _} = Application.ensure_all_started(:inets)

      assert_offer(fn port ->
        :httpc.request(
          :get,
          {~c"https://127.0.0.1:#{port}/", []},
          [ssl: [verify: :verify_none], timeout: 5_000],
          []
        )
      end)
    end

    test "a bare ssl:connect with no versions option" do
      assert_offer(fn port ->
        :ssl.connect(~c"127.0.0.1", port, [verify: :verify_none], 5_000)
      end)
    end

    test "WebSockex, the websocket client in the release" do
      assert_offer(fn port ->
        "wss://127.0.0.1:#{port}/"
        |> WebSockex.Conn.new(ssl_options: [verify: :verify_none])
        |> WebSockex.Conn.open_socket()
      end)
    end

    test "Postgrex with TLS, after its SSLRequest" do
      assert_offer(
        fn port ->
          {:ok, _} =
            Postgrex.start_link(
              hostname: "127.0.0.1",
              port: port,
              username: "probe",
              password: "probe",
              database: "probe",
              ssl: [verify: :verify_none],
              backoff_type: :stop,
              pool_size: 1
            )

          Process.sleep(:infinity)
        end,
        :postgres
      )
    end
  end

  ## The oracle

  defp otp_version_string do
    [:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end

  defp affected? do
    version = otp_version_string() |> String.split(".") |> Enum.map(&String.to_integer/1)
    hd(version) != 28 or version < @fixed_28
  end

  ## The census

  # The applications the release carries: the closure of :trinity's, kept to the ones this project
  # builds or OTP provides. An optional dependency can resolve to an archive installed on the
  # machine (igniter's `phx_new` did, here), which no release carries and CI does not have.
  defp release_applications do
    roots = [Mix.Project.build_path(), to_string(:code.root_dir())]

    [:trinity, :logger, :runtime_tools, :sasl]
    |> walk(MapSet.new())
    |> Enum.filter(fn app ->
      dir = :code.lib_dir(app)
      is_list(dir) and String.starts_with?(to_string(dir), roots)
    end)
  end

  defp walk([], seen), do: seen

  defp walk([app | rest], seen) do
    if MapSet.member?(seen, app) do
      walk(rest, seen)
    else
      _ = Application.load(app)

      deps =
        (Application.spec(app, :applications) || []) ++
          (Application.spec(app, :included_applications) || [])

      walk(deps ++ rest, MapSet.put(seen, app))
    end
  end

  # {app, module, imports} for every module of every application in the release.
  defp modules do
    for app <- release_applications(),
        mod <- Application.spec(app, :modules) || [],
        path = :code.which(mod),
        is_list(path),
        {:ok, {^mod, [imports: imports]}} <- [:beam_lib.chunks(path, [:imports])],
        do: {app, mod, imports}
  end

  # The atom table and the literal table of a module's BEAM file, where a `versions: [...]` list
  # lives; documentation chunks are left out, so a mention in a docstring does not count.
  defp code_names(mod) do
    {:ok, _, chunks} = mod |> :code.which() |> :beam_lib.all_chunks()

    literals =
      for {~c"LitT", <<size::32, data::binary>>} <- chunks,
          do: if(size == 0, do: data, else: :zlib.uncompress(data))

    IO.iodata_to_binary(for({~c"AtU8", atoms} <- chunks, do: atoms) ++ literals)
  end

  defp callers_of(match?, app_filter) do
    for {app, mod, imports} <- modules(),
        app_filter.(app),
        Enum.any?(imports, match?),
        uniq: true,
        do: mod
  end

  defp transitive_callers(targets) do
    all = modules()
    grow(all, targets, MapSet.new())
  end

  defp grow(all, frontier, seen) do
    new =
      for {app, mod, imports} <- all,
          not MapSet.member?(seen, {app, mod}),
          Enum.any?(imports, fn {m, _, _} -> MapSet.member?(frontier, m) end),
          into: MapSet.new(),
          do: {app, mod}

    if MapSet.size(new) == 0 do
      MapSet.to_list(seen)
    else
      grow(all, MapSet.new(new, &elem(&1, 1)), MapSet.union(seen, new))
    end
  end

  defp assert_census(found, named, what) do
    unnamed = Enum.reject(found, &Map.has_key?(named, &1))
    stale = named |> Map.keys() |> Enum.reject(&(&1 in found))

    assert unnamed == [],
           "modules in the release that #{what} and are not in this census: #{inspect(unnamed)}. " <>
             "Name each with the layer that keeps it off TLS 1.3, or clamp it (ADR-0014)."

    assert stale == [],
           "named in this census but no longer found in the release: #{inspect(stale)}; remove them"
  end

  ## Finch instances

  # A Finch instance is a Registry whose metadata carries its pool configuration
  # (deps/finch/lib/finch.ex, init/1). Every registered name is tried; anything else is skipped.
  defp finch_instances do
    for name <- Process.registered(),
        {:ok, %{default_pool_config: _} = config} <- [registry_config(name)],
        do: {name, config}
  end

  defp registry_config(name) do
    Registry.meta(name, :config)
  rescue
    _ -> :error
  end

  defp versions(pool) do
    pool |> Map.get(:conn_opts, []) |> Keyword.get(:transport_opts, []) |> Keyword.get(:versions)
  end

  ## The probe

  defp assert_offer(client, mode \\ :tls) do
    offered = offer(client, mode)

    if affected?() do
      refute @tls13 in offered,
             "OTP #{otp_version_string()} carries CVE-2026-89422 and this client offered TLS 1.3 " <>
               "(offered #{inspect(Enum.map(offered, &version_name/1))})"

      assert @tls12 in offered
    else
      assert @tls13 in offered == :"tlsv1.3" in :ssl.versions()[:available],
             "OTP #{otp_version_string()} is fixed, and this client is still clamped"
    end
  end

  defp version_name(@tls13), do: :"tlsv1.3"
  defp version_name(@tls12), do: :"tlsv1.2"
  defp version_name(other), do: other

  # Starts a loopback listener, runs the client against it in a process of its own (the client
  # fails when the listener hangs up, which is expected), and returns the versions the first
  # ClientHello offered.
  defp offer(client, mode) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    test = self()
    {:ok, acceptor} = Task.start(fn -> accept(listener, test, mode) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)
    {:ok, runner} = Task.start(fn -> client.(port) end)

    receive do
      {:client_hello, offered} ->
        Process.exit(runner, :kill)
        Process.exit(acceptor, :kill)
        offered
    after
      10_000 ->
        Process.exit(runner, :kill)
        Process.exit(acceptor, :kill)
        flunk("no ClientHello reached the probe within 10 s")
    end
  end

  defp accept(listener, test, mode) do
    {:ok, socket} = :gen_tcp.accept(listener)
    if mode == :postgres, do: postgres_ssl_request(socket)
    {:ok, <<22, _major, _minor, length::16>>} = :gen_tcp.recv(socket, 5, 5_000)
    {:ok, record} = :gen_tcp.recv(socket, length, 5_000)
    send(test, {:client_hello, client_hello_versions(record)})
    :gen_tcp.close(socket)
  end

  # Postgres asks for TLS in the clear first: an 8-byte SSLRequest, answered with "S".
  defp postgres_ssl_request(socket) do
    {:ok, <<8::32, 80_877_103::32>>} = :gen_tcp.recv(socket, 8, 5_000)
    :ok = :gen_tcp.send(socket, "S")
  end

  # RFC 8446 section 4.1.2. A client that offers TLS 1.3 says so in supported_versions (43);
  # without that extension, it offers only its legacy_version.
  defp client_hello_versions(
         <<1, _length::24, legacy::16, _random::binary-32, sid::8, _sid::binary-size(sid),
           suites::16, _suites::binary-size(suites), comp::8, _comp::binary-size(comp),
           ext_length::16, extensions::binary-size(ext_length), _::binary>>
       ) do
    case extension(extensions, 43) do
      <<n::8, versions::binary-size(n)>> -> for <<v::16 <- versions>>, do: v
      nil -> [legacy]
    end
  end

  defp extension(<<type::16, n::16, data::binary-size(n), _::binary>>, type), do: data

  defp extension(<<_::16, n::16, _::binary-size(n), rest::binary>>, type),
    do: extension(rest, type)

  defp extension(<<>>, _type), do: nil
end
