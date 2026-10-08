# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.InspectTest do
  @moduledoc """
  Slice 130, AC1 and AC6, the decisions `mix trinity.image.inspect` makes about an image's layers,
  on real layer tarballs built here. The task's run on built images (the hardened one passing, the
  slice 061 one and two images that revert a property on top of the hardened one failing) needs
  Docker and is in the slice's PROOF.md; this file proves each rule discriminates.

  A clean pair of layers is asserted to pass first, and each test then plants one thing and
  asserts the violation names it, so a plant cannot pass by tripping some other rule.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Trinity.Image.Inspect

  @moduletag :tmp_dir

  # Assembled so the tree's own secrets scan does not read these source lines as keys.
  @key "-----BEGIN " <>
         "PRIVATE KEY-----\n" <>
         String.duplicate("QUJD", 16) <> "\n-----END " <> "PRIVATE KEY-----\n"
  @other_key "-----BEGIN " <>
               "PRIVATE KEY-----\n" <>
               String.duplicate("WFla", 16) <> "\n-----END " <> "PRIVATE KEY-----\n"
  @cert "-----BEGIN CERTIFICATE-----\n" <>
          String.duplicate("TUlJ", 16) <> "\n-----END CERTIFICATE-----\n"
  @config %{"config" => %{"User" => "10001:10001", "Env" => ["RELEASE_DISTRIBUTION=none"]}}

  # A layer tarball from `files` ({path, content | :dir, mode}), unpacked the way the task does.
  defp layer(tmp, name, files) do
    src = Path.join(tmp, name)

    for {path, content, mode} <- files do
      full = Path.join(src, path)

      if content == :dir do
        File.mkdir_p!(full)
      else
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
      end

      # The system chmod, not File.chmod!/2: measured, File.chmod!/2 drops the sticky bit on a
      # directory (1777 becomes 0777), which made every fixture carry an unsticky /tmp.
      {_, 0} = System.cmd("chmod", [Integer.to_string(mode, 8), full])
    end

    tar = Path.join(tmp, name <> ".tar")

    {_, 0} =
      System.cmd("tar", ["-C", src, "--owner=0", "--group=0", "--numeric-owner", "-cf", tar, "."])

    Inspect.read_layer(tar, Path.join(tmp, name <> "-unpacked"))
  end

  defp base(tmp, extra \\ []) do
    layer(tmp, "base", [
      {"etc/passwd", "root:x:0:0:root:/root:/bin/bash\n", 0o644},
      {"usr/bin/bash", "#!", 0o755},
      {"etc/pki/product-default/479.pem", @cert, 0o644} | extra
    ])
  end

  defp added(tmp, extra \\ [], name \\ "added") do
    layer(tmp, name, [
      {"etc/passwd",
       "root:x:0:0:root:/root:/bin/bash\ntrinity:x:10001:10001::/data:/sbin/nologin\n", 0o644},
      {"opt/trinity/bin/headless", "#!/bin/sh\n", 0o755},
      {"opt/trinity/lib/trinity-0.1.0/priv/skills/web/SKILL.md", "# a skill\n", 0o644},
      {"usr/share/licenses/zlib/README", "licence\n", 0o644},
      {"tmp", :dir, 0o1777} | extra
    ])
  end

  defp check(tmp, opts \\ []) do
    Inspect.check(%{
      config: Keyword.get(opts, :config, @config),
      base: [Keyword.get_lazy(opts, :base, fn -> base(tmp) end)],
      added: Keyword.get_lazy(opts, :added, fn -> [added(tmp)] end),
      allowances: Keyword.get(opts, :allowances, [])
    })
  end

  defp only(result, expected) do
    assert result.violations == [expected],
           "expected only #{inspect(expected)}, got #{inspect(result.violations)}"
  end

  test "a clean image passes, and what the base carries is listed as inherited", %{tmp_dir: tmp} do
    result = check(tmp)
    assert result.violations == []
    assert result.inherited == ["/etc/pki/product-default/479.pem: certificate material"]
  end

  describe "AC1" do
    test "no user, root, UID 0 and a UID below 1000 are refused", %{tmp_dir: tmp} do
      for {user, expected} <- [
            {"", "AC1: the image sets no user, so it runs as root"},
            {"root", "AC1: the image's user root is root"},
            {"0:0", "AC1: the image's user 0:0 is root"},
            {"999", "AC1: the image's user 999 has UID 999, below 1000"}
          ] do
        only(check(tmp, config: put_in(@config, ["config", "User"], user)), expected)
      end
    end

    test "a user name resolves through the image's own /etc/passwd", %{tmp_dir: tmp} do
      assert check(tmp, config: put_in(@config, ["config", "User"], "trinity")).violations == []

      only(
        check(tmp, config: put_in(@config, ["config", "User"], "nobody")),
        "AC1: the image's user nobody is not in its /etc/passwd"
      )
    end
  end

  describe "AC6, in the layers the image adds" do
    for {label, file, expected} <- [
          {"a package manager", {"usr/bin/dnf", "#!", 0o755},
           "AC6: /usr/bin/dnf: a package manager"},
          {"a build tool", {"usr/bin/gcc", "#!", 0o755}, "AC6: /usr/bin/gcc: a build tool"},
          {"Mix in the release", {"opt/trinity/lib/mix-1.20.4", :dir, 0o755},
           "AC6: /opt/trinity/lib/mix-1.20.4: mix, a build-time library, carried as a release application"},
          {"shell history", {"data/.bash_history", "ls\n", 0o600},
           "AC6: /data/.bash_history: shell history"},
          {"documentation", {"usr/share/doc/zlib/NEWS", "x", 0o644},
           "AC6: /usr/share/doc/zlib/NEWS: documentation"},
          {"a README", {"opt/trinity/README.md", "x", 0o644},
           "AC6: /opt/trinity/README.md: documentation"},
          {"a SUID bit", {"opt/trinity/bin/tool", "x", 0o4755},
           "AC6: /opt/trinity/bin/tool: SUID or SGID bit set (mode 04755)"},
          {"a world-writable file", {"opt/trinity/env", "x", 0o666},
           "AC6: /opt/trinity/env: world-writable (mode 0666)"},
          {"an unsticky world-writable directory", {"opt/trinity/drop", :dir, 0o777},
           "AC6: /opt/trinity/drop: world-writable (mode 0777)"},
          {"a certificate", {"opt/trinity/ca.pem", @cert, 0o644},
           "AC6: /opt/trinity/ca.pem: certificate material"}
        ] do
      test "#{label} is refused", %{tmp_dir: tmp} do
        only(check(tmp, added: [added(tmp, [unquote(Macro.escape(file))])]), unquote(expected))
      end
    end

    test "a file deleted by a later layer is still found", %{tmp_dir: tmp} do
      planted = added(tmp, [{"usr/bin/dnf", "#!", 0o755}], "planted")
      removed = layer(tmp, "removed", [{"usr/bin/.wh.dnf", "", 0o644}])
      only(check(tmp, added: [planted, removed]), "AC6: /usr/bin/dnf: a package manager")
    end

    test "a certificate identical to the base's at the same path is not added material", %{
      tmp_dir: tmp
    } do
      copy = added(tmp, [{"etc/pki/product-default/479.pem", @cert, 0o644}])
      assert check(tmp, added: [copy]).violations == []
    end

    test "/etc/passwd made writable is refused twice: its mode, and world-writable", %{
      tmp_dir: tmp
    } do
      result =
        check(tmp,
          added: [
            layer(tmp, "added", [
              {"etc/passwd", "root:x:0:0::/:/bin/sh\ntrinity:x:10001:10001::/data:/x\n", 0o666}
            ])
          ]
        )

      assert "AC6: /etc/passwd: world-writable (mode 0666)" in result.violations

      assert Enum.any?(
               result.violations,
               &(&1 =~
                   ~r/^AC6: \/etc\/passwd is mode, owner, group \{"0666", 0, 0\}; the base's is \{"0644", 0, 0\}/)
             )
    end
  end

  describe "AC6, anywhere in the image" do
    test "a private key in the base is refused too", %{tmp_dir: tmp} do
      only(
        check(tmp, base: base(tmp, [{"etc/ssh/key.pem", @key, 0o600}])),
        "AC6: /etc/ssh/key.pem: a private key"
      )
    end

    test "a key header with no key after it is not a key", %{tmp_dir: tmp} do
      header = "constant: -----BEGIN " <> "RSA PRIVATE KEY----- used by a parser"

      assert check(tmp, added: [added(tmp, [{"usr/lib64/libtls.so", header, 0o755}])]).violations ==
               []
    end

    test "a distribution cookie and key files by name are refused", %{tmp_dir: tmp} do
      result =
        check(tmp,
          added: [
            added(tmp, [
              {"opt/trinity/releases/COOKIE", "abc", 0o400},
              {"root/.ssh/id_rsa", "x", 0o600}
            ])
          ]
        )

      assert Enum.sort(result.violations) == [
               "AC6: /opt/trinity/releases/COOKIE: an Erlang distribution cookie, a credential everyone who pulls the image would hold",
               "AC6: /root/.ssh/id_rsa: key material by its name"
             ]
    end

    test "distribution not turned off is refused", %{tmp_dir: tmp} do
      only(
        check(tmp, config: put_in(@config, ["config", "Env"], [])),
        "hardening: RELEASE_DISTRIBUTION is not none, so the release starts a distribution listener"
      )
    end
  end

  describe "allowances" do
    test "a certificate under an allowed prefix is allowed, with its reason", %{tmp_dir: tmp} do
      allowance = %{
        "path" => "/etc/pki/ca-trust/",
        "kinds" => ["certificate"],
        "reason" => "the OS trust store"
      }

      result =
        check(tmp,
          added: [added(tmp, [{"etc/pki/ca-trust/bundle.pem", @cert, 0o644}])],
          allowances: [allowance]
        )

      assert result.violations == []

      assert result.allowed == [
               "/etc/pki/ca-trust/bundle.pem: certificate material (the OS trust store)"
             ]
    end

    test "an allowance that allows nothing fails as stale", %{tmp_dir: tmp} do
      allowance = %{
        "path" => "/etc/pki/ca-trust/",
        "kinds" => ["certificate"],
        "reason" => "the OS trust store"
      }

      only(
        check(tmp, allowances: [allowance]),
        "AC6: allowance /etc/pki/ca-trust/ allows nothing in this image; remove it from ci/headless/image_allowances.yaml"
      )
    end

    test "a private key is allowed only by the SHA-256 of its PEM block", %{tmp_dir: tmp} do
      sha = :crypto.hash(:sha256, String.trim_trailing(@key, "\n")) |> Base.encode16(case: :lower)
      file = {"opt/trinity/lib/jose/ebin/jose_server.beam", "code" <> @key <> "code", 0o644}

      allowance = %{
        "path" => "/opt/trinity/lib/jose/ebin/jose_server.beam",
        "kinds" => ["private_key"],
        "sha256" => [sha],
        "reason" => "a published test key"
      }

      assert check(tmp, added: [added(tmp, [file])], allowances: [allowance]).violations == []

      second = {"opt/trinity/lib/jose/ebin/jose_server.beam", "code" <> @key <> @other_key, 0o644}
      result = check(tmp, added: [added(tmp, [second])], allowances: [allowance])

      assert "AC6: /opt/trinity/lib/jose/ebin/jose_server.beam: a private key" in result.violations
    end

    test "a kind that cannot be allowed is refused as an allowance", %{tmp_dir: tmp} do
      allowance = %{
        "path" => "/usr/bin/dnf",
        "kinds" => ["package_manager"],
        "reason" => "convenient"
      }

      result =
        check(tmp, added: [added(tmp, [{"usr/bin/dnf", "#!", 0o755}])], allowances: [allowance])

      assert "AC6: /usr/bin/dnf: a package manager" in result.violations

      assert Enum.any?(
               result.violations,
               &(&1 =~ ~r/^AC6: allowance "\/usr\/bin\/dnf": kinds must be some of/)
             )
    end

    test "the allowances file in the tree is well formed", %{tmp_dir: tmp} do
      {:ok, %{"allowances" => allowances}} =
        YamlElixir.read_from_file("ci/headless/image_allowances.yaml")

      malformed =
        check(tmp, allowances: allowances).violations
        |> Enum.reject(&(&1 =~ "allows nothing in this image"))

      assert malformed == []
    end
  end
end
