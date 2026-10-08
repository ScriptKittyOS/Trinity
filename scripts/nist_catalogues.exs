# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Derives the two identifier lists `docs/regulated/control-mapping.md` is checked against, from
# NIST's own OSCAL catalogues, and refuses any catalogue that is not the pinned one.
#
#   elixir scripts/nist_catalogues.exs --sp800-53 PATH --sp800-218 PATH          # write
#   elixir scripts/nist_catalogues.exs --sp800-53 PATH --sp800-218 PATH --check  # compare
#
# The two catalogues come from `usnistgov/oscal-content` at the commit below:
#
#   curl -fsSLO https://raw.githubusercontent.com/usnistgov/oscal-content/<commit>/nist.gov/SP800-53/rev5/json/NIST_SP-800-53_rev5_catalog.json
#   curl -fsSLO https://raw.githubusercontent.com/usnistgov/oscal-content/<commit>/nist.gov/SP800-218/ver1/json/NIST_SP800-218_ver1_catalog.json
#
# They are 10.4 MB and 0.25 MB and stay outside the tree. What enters it is the identifiers, each
# with its status and its family, in `test/support/fixtures/nist/`, with the URL, the commit and
# the SHA-256 of the file it came from in the header. Titles are left out on purpose: a title is
# not needed to refuse an identifier the catalogue does not have.
#
# This is not in `mix gate`. It needs the catalogues, which the gate does not download, and what it
# checks changes when NIST publishes, not when this tree does. `--check` is how anyone re-derives
# the committed lists from NIST's files and confirms they are the same bytes.

defmodule NistCatalogues do
  @commit "78650f02ad9321bb7b817846f8fbd4f2bcd620de"
  @base "https://raw.githubusercontent.com/usnistgov/oscal-content/#{@commit}/nist.gov"

  @sources %{
    sp800_53: %{
      url: "#{@base}/SP800-53/rev5/json/NIST_SP-800-53_rev5_catalog.json",
      sha256: "01f37cf90ea99d92242c936cbfbdebcc338eef1f71454e2acac36cc56e9bc062",
      out: "test/support/fixtures/nist/sp800-53r5.tsv",
      heading: "NIST SP 800-53 Rev. 5 controls and control enhancements"
    },
    sp800_218: %{
      url: "#{@base}/SP800-218/ver1/json/NIST_SP800-218_ver1_catalog.json",
      sha256: "b01634a5fdb382e7a12660c379a4d0bc3a2b8e29abccf2861834880005137117",
      out: "test/support/fixtures/nist/sp800-218.tsv",
      heading: "NIST SP 800-218 (SSDF 1.1) practices and tasks"
    }
  }

  def main(argv) do
    {opts, _, invalid} =
      OptionParser.parse(argv, strict: [sp800_53: :string, sp800_218: :string, check: :boolean])

    paths = %{sp800_53: opts[:sp800_53], sp800_218: opts[:sp800_218]}

    if invalid != [] or Enum.any?(paths, fn {_, p} -> is_nil(p) end) do
      IO.puts(
        :stderr,
        "usage: elixir scripts/nist_catalogues.exs --sp800-53 PATH --sp800-218 PATH [--check]"
      )

      System.halt(2)
    end

    results =
      for {key, path} <- paths do
        source = Map.fetch!(@sources, key)
        bytes = File.read!(path)
        verify_digest!(path, bytes, source.sha256)
        text = render(key, source, JSON.decode!(bytes)["catalog"])
        {source.out, text}
      end

    if opts[:check], do: check(results), else: write(results)
  end

  defp verify_digest!(path, bytes, expected) do
    got = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if got != expected do
      IO.puts(
        :stderr,
        "REFUSED #{path}: SHA-256 #{got}, pinned #{expected}. Not the catalogue at #{@commit}."
      )

      System.halt(1)
    end
  end

  defp write(results) do
    for {out, text} <- results do
      File.mkdir_p!(Path.dirname(out))
      File.write!(out, text)
      IO.puts("nist_catalogues: wrote #{out} (#{count(text)} identifiers)")
    end
  end

  defp check(results) do
    stale =
      for {out, text} <- results, File.read(out) != {:ok, text} do
        IO.puts(:stderr, "STALE #{out}: not what the pinned catalogue derives")
        out
      end

    if stale == [] do
      IO.puts("nist_catalogues: OK. Both lists are what the pinned catalogues derive")
    else
      System.halt(1)
    end
  end

  defp count(text),
    do: text |> String.split("\n") |> Enum.count(&(&1 =~ ~r/^(control|practice|task)\t/))

  defp render(_key, source, catalog) do
    meta = catalog["metadata"]

    header = [
      "# #{source.heading}. Derived; regenerate, never edit.",
      "# source: #{source.url}",
      "# commit: #{@commit}",
      "# sha256: #{source.sha256}",
      "# catalogue: version #{meta["version"]}, last-modified #{meta["last-modified"]}, OSCAL #{meta["oscal-version"]}",
      "# licence: CC0-1.0, the LICENSE.md of usnistgov/oscal-content at that commit",
      "# derived by: elixir scripts/nist_catalogues.exs --sp800-53 PATH --sp800-218 PATH"
    ]

    rows =
      Enum.flat_map(catalog["groups"], fn group ->
        family = label(group) |> family_code(group["id"])
        ["family\t#{family}\t#{group["title"]}" | walk(group["controls"] || [], family, 0)]
      end)

    Enum.join(header ++ rows, "\n") <> "\n"
  end

  # SP 800-53 nests enhancements under controls; SP 800-218 nests tasks under practices. The kind
  # is the depth, and the label is the one NIST prints, never a reconstruction from the id.
  defp walk(controls, family, depth) do
    Enum.flat_map(controls, fn control ->
      line =
        "#{kind(control["id"], depth)}\t#{identifier(control)}\t#{status(control)}\t#{family}"

      [line | walk(control["controls"] || [], family, depth + 1)]
    end)
  end

  defp kind(id, depth) do
    cond do
      not ssdf?(id) -> "control"
      depth == 0 -> "practice"
      true -> "task"
    end
  end

  defp ssdf?(id), do: String.match?(id, ~r/^[A-Z]{2}\.\d/)

  # SSDF's ids are its identifiers (`PO.1.1`); its labels are the practice's name. SP 800-53's ids
  # are lower case (`ac-2.1`) and its plain label is the identifier as NIST prints it (`AC-2(1)`),
  # not the zero-padded one.
  defp identifier(%{"id" => id} = control) do
    if ssdf?(id), do: id, else: label(control)
  end

  defp label(%{"props" => props} = item) do
    Enum.find_value(props, fn p -> (p["name"] == "label" and is_nil(p["class"])) && p["value"] end) ||
      item["id"]
  end

  defp label(item), do: item["id"]

  # SSDF groups are labelled "Prepare the Organization (PO)"; SP 800-53 groups carry no label and
  # their id is the family in lower case.
  defp family_code(label, id) do
    case Regex.run(~r/\(([A-Z]{2})\)$/, label) do
      [_, code] -> code
      nil -> String.upcase(id)
    end
  end

  defp status(%{"props" => props}) do
    Enum.find_value(props, "active", fn p -> p["name"] == "status" && p["value"] end)
  end

  defp status(_), do: "active"
end

NistCatalogues.main(System.argv())
