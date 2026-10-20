# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule CiPinsTest do
  @moduledoc """
  Slice 141: the FIPS leg's image installs the Hex and rebar3 the Iron Bank manifest declares, by
  the same URL and SHA-512, and never "the newest".

  The image used to run `mix local.hex --force && mix local.rebar --force`. Rebuilt for OTP
  28.5.0.8 it got Hex 2.5.3 where the image of 2026-10-08 had 2.5.1, and the bill of materials names
  the running Hex, so the gate's `THIRD_PARTY_LICENSES.md` check failed on the new image. An
  unpinned install is invisible until the image is rebuilt, which is why this is a test and not a
  comment.
  """
  use ExUnit.Case, async: true

  @containerfile "ci/fips/Containerfile"
  @manifest "ci/ironbank/hardening_manifest.yaml"

  # `{url, sha512}` of the manifest resource whose filename starts with `prefix`.
  defp resource(prefix) do
    %{"resources" => resources} = YamlElixir.read_from_file!(@manifest)

    %{"url" => url, "validation" => %{"type" => "sha512", "value" => sha512}} =
      Enum.find(resources, &String.starts_with?(&1["filename"], prefix))

    {url, sha512}
  end

  defp arg(text, name) do
    [_, value] = Regex.run(~r/^ARG #{name}=(\S+)$/m, text)
    value
  end

  test "Hex and rebar3 come from the manifest's URLs, checked against its SHA-512s" do
    text = File.read!(@containerfile)

    for {prefix, arg_name} <- [{"hex-", "HEX_SHA512"}, {"rebar3-", "REBAR3_SHA512"}] do
      {url, sha512} = resource(prefix)
      assert text =~ url, "#{@containerfile} does not fetch #{url}"
      assert arg(text, arg_name) == sha512, "#{arg_name} is not the manifest's SHA-512 for #{url}"
      assert text =~ ~s|echo "${#{arg_name}}  /tmp/#{Path.basename(url)}" \| sha512sum -c -|
    end
  end

  test "nothing installs the newest Hex or rebar" do
    text = File.read!(@containerfile)
    refute text =~ ~r/^(?!#).*mix local\.hex/m
    refute text =~ ~r/^(?!#).*mix local\.rebar\s+--force/m
  end
end
