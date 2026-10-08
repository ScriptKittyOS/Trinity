# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule IronbankSubmissionTest do
  @moduledoc """
  Slice 130, AC2, AC2a, AC6 (the Dockerfile half) and AC6a: `ci/ironbank/` is a submission Iron
  Bank's rules accept, and the published build pins every base by digest.

  The first test reads the tree as it is. Every other test plants one violation into that same
  tree, read once, and asserts that the lint reports it **for its own reason**: the assertion
  names the message, and the unplanted tree is asserted clean first, so a plant that tripped some
  other rule would not pass. The planted reds the slice's proof requires are here by name: a
  literal registry host (AC2), a tag-not-digest base (AC2), and `curl` in the build (AC2a).
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Trinity.Ironbank.Lint

  @tree Lint.read_tree(".")

  defp violations(tree, opts \\ []), do: Lint.violations(tree, opts)

  defp plant(field, from, to) do
    text = Map.fetch!(@tree, field)
    assert String.contains?(text, from), "the plant's anchor #{inspect(from)} is not in #{field}"
    Map.put(@tree, field, String.replace(text, from, to, global: false))
  end

  defp assert_only(tree, pattern) do
    found = violations(tree)
    assert found != [], "the plant produced no violation"

    assert Enum.all?(found, &(&1 =~ pattern)),
           "expected only #{inspect(pattern)}, got:\n" <> Enum.join(found, "\n")

    found
  end

  test "the tree as it stands has no violation" do
    assert violations(@tree) == []
  end

  test "the submission's LICENSE is the project's, byte for byte" do
    assert File.read!("ci/ironbank/LICENSE") == File.read!("LICENSE")
  end

  describe "AC2: bases" do
    test "a FROM naming a registry host is refused (planted red)" do
      tree =
        plant(
          :dockerfile,
          "FROM ${BASE_REGISTRY}/${BASE_IMAGE}:${BASE_TAG} AS runtime-base",
          "FROM registry.access.redhat.com/ubi9/ubi-micro:9.8 AS runtime-base"
        )

      assert_only(
        tree,
        ~r/^AC2: .*FROM registry\.access\.redhat\.com\/ubi9\/ubi-micro:9\.8 does not take its registry/
      )
    end

    test "a published base pinned by tag and not by digest is refused (planted red)" do
      tree =
        plant(
          :bases_env,
          "BASE_TAG=9.8@sha256:932aec77f5b86a5dba854a18b14a38725b296967e7dc9c7a1f4d7f0bf82e1ce5",
          "BASE_TAG=9.8"
        )

      [_ | _] =
        assert_only(
          tree,
          ~r/^AC2: .*resolves FROM to registry\.access\.redhat\.com\/ubi9\/ubi-micro:9\.8, which is not pinned by digest/
        )
    end

    test "a variable the published build does not set is refused" do
      tree = plant(:bases_env, "BUILDER_TAG=", "UNUSED_TAG=")
      assert_only(tree, ~r/^AC2: .*bases\.env does not set BUILDER_TAG/)
    end

    test "a FROM variable the manifest does not set is refused" do
      tree =
        Map.update!(
          @tree,
          :manifest,
          &update_in(&1, ["args"], fn a -> Map.delete(a, "BUILDER_TAG") end)
        )

      assert_only(tree, ~r/^AC2: .*\$\{BUILDER_TAG\} is not set by hardening_manifest\.yaml/)
    end
  end

  describe "AC2a: no network in the build" do
    test "curl in a RUN is refused (planted red)" do
      tree =
        plant(
          :dockerfile,
          "&& make install \\",
          "&& curl -fsSL -o /tmp/x example.invalid \\\n    && make install \\"
        )

      assert_only(tree, ~r/^AC2a: Dockerfile line \d+: curl reaches the network/)
    end

    test "wget in a submission script is refused, even in a comment" do
      tree = %{
        @tree
        | scripts: [
            {"ci/ironbank/scripts/entrypoint.sh",
             "#!/bin/sh\n# wget is never called\nexec \"$@\"\n"}
          ]
      }

      assert_only(
        tree,
        ~r/^AC2a: ci\/ironbank\/scripts\/entrypoint\.sh line 2: wget reaches the network/
      )
    end

    test "a URL anywhere in the Dockerfile is refused" do
      tree =
        plant(:dockerfile, "# The toolchain:", "# See https://example.invalid. The toolchain:")

      assert_only(tree, ~r/^AC2a: Dockerfile line \d+: a URL/)
    end

    test "ADD is refused" do
      tree =
        plant(
          :dockerfile,
          "COPY --from=rootfs /rootfs/ /",
          "COPY --from=rootfs /rootfs/ /\nADD trinity-src.tar.gz /opt/"
        )

      assert_only(tree, ~r/^AC2a: Dockerfile line \d+: ADD is prohibited/)
    end

    test "copying a file no resource declares is refused" do
      tree =
        plant(
          :dockerfile,
          "trinity-src.tar.gz trinity-hex-deps.tar.gz",
          "trinity-src.tar.gz trinity-hex-deps.tar.gz undeclared.bin"
        )

      assert_only(
        tree,
        ~r/^AC2a: Dockerfile line \d+: COPY undeclared\.bin is not a resource declared/
      )
    end

    test "a declared resource the Dockerfile never copies is refused" do
      tree = plant(:dockerfile, " rebar3-3.25.1-otp-28 /build/resources/", " /build/resources/")
      found = violations(tree)

      assert "AC2a: resource rebar3-3.25.1-otp-28 is declared in hardening_manifest.yaml but never copied" in found
    end

    test "a resource whose digest is not lowercase hex of the right length is refused" do
      tree =
        Map.update!(@tree, :manifest, fn m ->
          update_in(m, ["resources", Access.at(0), "validation", "value"], &String.upcase/1)
        end)

      assert_only(
        tree,
        ~r/^AC2a: resource otp_src_.*: its sha256 value is not 64 lowercase hex digits/
      )
    end
  end

  describe "AC6: what the Dockerfile may not do" do
    for {label, command, expected} <- [
          {"chmod 777", "chmod 777 /opt/trinity", "chmod 777 makes a file world-writable"},
          {"chmod 4755", "chmod 4755 /opt/trinity/bin/headless",
           "chmod 4755 sets a SUID or SGID bit"},
          {"chmod u+s", "chmod u+s /opt/trinity/bin/headless",
           "chmod u+s sets a SUID or SGID bit"},
          {"chmod -R o+w", "chmod -R o+w /data", "chmod o+w makes a file world-writable"},
          {"--nogpgcheck", "dnf -y --nogpgcheck install zlib",
           "disables package signature checks"},
          {"rpm --import elsewhere", "rpm --import /tmp/key.asc",
           "rpm --import /tmp/key.asc is not from a gpg/ folder"},
          {"a write to /etc/passwd",
           "echo trinity:x:10001:10001::/data:/sbin/nologin >> /rootfs/etc/passwd",
           "writes or changes /etc/passwd"}
        ] do
      test "#{label} is refused" do
        tree =
          plant(
            :dockerfile,
            "    && install -d -o 10001",
            "    && #{unquote(command)} \\\n    && install -d -o 10001"
          )

        found = assert_only(tree, ~r/^AC6: Dockerfile line \d+: /)
        assert Enum.any?(found, &String.contains?(&1, unquote(expected))), Enum.join(found, "\n")
      end
    end

    test "rpm --import from a gpg/ folder is accepted" do
      tree =
        plant(
          :dockerfile,
          "    && install -d -o 10001",
          "    && rpm --import /tmp/gpg/vendor.asc \\\n    && install -d -o 10001"
        )

      assert violations(tree) == []
    end

    test "a final USER of root is refused" do
      tree = plant(:dockerfile, "USER 10001:10001", "USER root")
      assert_only(tree, ~r/^AC6: Dockerfile line \d+: the final USER root is not a numeric UID/)
    end

    test "no USER in the final stage is refused" do
      tree = plant(:dockerfile, "USER 10001:10001\n", "")
      assert_only(tree, ~r/^AC6: the final stage sets no USER/)
    end
  end

  describe "AC6a: Iron Bank's layout" do
    test "a conf/ directory is refused and named" do
      tree = %{@tree | entries: Enum.sort(["conf" | @tree.entries])}

      assert_only(
        tree,
        ~r/^AC6a: ci\/ironbank\/conf is not part of .*the configuration directory is config\//
      )
    end

    test "a missing README.md is refused" do
      tree = %{@tree | entries: @tree.entries -- ["README.md"]}
      assert_only(tree, ~r/^AC6a: ci\/ironbank\/README\.md is required/)
    end

    test "a second recipe beside the Dockerfile is refused" do
      tree = %{@tree | entries: Enum.sort(["Containerfile" | @tree.entries])}
      assert_only(tree, ~r/^AC6a: ci\/ironbank\/Containerfile is not part of/)
    end

    test "a LABEL in the Dockerfile is refused" do
      tree =
        plant(
          :dockerfile,
          "WORKDIR /opt/trinity\n",
          "WORKDIR /opt/trinity\nLABEL org.opencontainers.image.title=trinity\n"
        )

      assert_only(tree, ~r/^AC6a: Dockerfile line \d+: LABEL belongs in hardening_manifest\.yaml/)
    end

    test "a first tag of latest, BASE_REGISTRY in args, and a missing label are refused" do
      tree =
        Map.update!(@tree, :manifest, fn m ->
          m
          |> Map.put("tags", ["latest", "0.1.0"])
          |> put_in(["args", "BASE_REGISTRY"], "registry1.dso.mil")
          |> update_in(["labels"], &Map.delete(&1, "org.opencontainers.image.vendor"))
        end)

      found = violations(tree)
      assert "AC6a: the first manifest tag may not be latest" in found
      assert "AC6a: manifest args may not set BASE_REGISTRY; the pipeline does" in found
      assert "AC6a: manifest label org.opencontainers.image.vendor is required" in found
      assert length(found) == 3
    end

    test "a manifest version that disagrees with mix.exs is refused" do
      tree = %{@tree | version: "9.9.9"}
      found = violations(tree)
      assert "AC6a: the first manifest tag 0.1.0 is not mix.exs's version 9.9.9" in found

      assert "AC6a: label org.opencontainers.image.version is not mix.exs's version 9.9.9" in found
    end

    test "an OTP resource that disagrees with .tool-versions is refused" do
      tree = %{
        @tree
        | tool_versions: String.replace(@tree.tool_versions, "erlang 28.5.0.5", "erlang 28.5.0.7")
      }

      assert_only(
        tree,
        ~r/^AC6a: no resource otp_src_28\.5\.0\.7\.tar\.gz, the OTP 28\.5\.0\.7 that \.tool-versions names/
      )
    end
  end

  describe "holds" do
    test "a held resource that is now declared is stale" do
      tree =
        Map.update!(@tree, :manifest, fn m ->
          resource = %{
            "url" => "https://example.invalid/trinity-src.tar.gz",
            "filename" => "trinity-src.tar.gz",
            "validation" => %{"type" => "sha256", "value" => String.duplicate("a", 64)}
          }

          Map.update!(m, "resources", &(&1 ++ [resource]))
        end)

      assert "holds: trinity-src.tar.gz is held but is now declared; remove the hold" in violations(
               tree
             )
    end

    test "a PENDING value with no hold is refused, and a hold with no PENDING value is stale" do
      tree =
        Map.update!(
          @tree,
          :manifest,
          &put_in(&1, ["maintainers", Access.at(0), "username"], "ayla")
        )

      assert "holds: maintainers[0].username is held but no longer PENDING" in violations(tree)

      tree =
        Map.update!(
          @tree,
          :manifest,
          &put_in(&1, ["labels", "org.opencontainers.image.url"], "PENDING")
        )

      assert "holds: manifest labels.org.opencontainers.image.url is PENDING with no hold" in violations(
               tree
             )
    end

    test "--submission refuses every open hold, and today there are three" do
      found = violations(@tree, submission: true)
      assert length(found) == 3
      assert Enum.all?(found, &String.starts_with?(&1, "AC7: open hold "))
    end
  end

  describe "mode_reasons/1" do
    test "reads numeric and symbolic modes" do
      assert Lint.mode_reasons("0755") == []
      assert Lint.mode_reasons("644") == []
      assert Lint.mode_reasons("1777") == ["chmod 1777 makes a file world-writable"]
      assert Lint.mode_reasons("2755") == ["chmod 2755 sets a SUID or SGID bit"]
      assert Lint.mode_reasons("go-w") == []
      assert Lint.mode_reasons("u+x") == []
      assert Lint.mode_reasons("+w") == ["chmod +w makes a file world-writable"]
      assert Lint.mode_reasons("a+rwx") == ["chmod a+rwx makes a file world-writable"]
      assert Lint.mode_reasons("g+s") == ["chmod g+s sets a SUID or SGID bit"]
    end
  end

  describe "the task" do
    test "passes on the tree, and --submission refuses the open holds" do
      assert :ok == Lint.run([])
      assert_raise Mix.Error, ~r/3 violation/, fn -> Lint.run(["--submission"]) end
    end
  end
end
