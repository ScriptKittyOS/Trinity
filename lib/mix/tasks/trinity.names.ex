defmodule Mix.Tasks.Trinity.Names do
  @shortdoc "Fails if a forbidden project name appears anywhere in the tracked tree"

  @moduledoc """
  The name check. Two policies, and which policy a name gets decides how it is matched.

  ## Zero-permitted-site names

  Matched by **salted digest**, never by a plaintext pattern, because a pattern file spelling
  them would itself be a hit — this module included. `priv/name_digests.txt` carries the salt
  and the digests only; the generator that produces it lives outside this repository.

  Tokenisation, applied identically to file contents and to file paths: downcase, split on
  every run of non-alphanumeric characters, digest each token with the committed salt, and
  compare against the committed set.

  **Stated limit.** A forbidden name glued inside a larger token with no separator is not
  detected. That is accepted: this is a tripwire against copy-paste drift, and copy-paste
  carries whole tokens.

  ## Permitted-site names

  The four platform names are matched in plain text and are allowed only inside one approved
  section of `README.md`. That section is located **by its heading text**, never by line
  number — measured at slice 000, a generator run moved it from lines 46–62 to 72–88, and a
  hard-coded range would then have been reading the wrong sixteen lines.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @digests_path "priv/name_digests.txt"
  @permitted_file "README.md"
  @permitted_begin "## Connecting Trinity to the platform"
  @permitted_end "## Principles baked into this plan"
  @platform_names ~w(requisition ultraviolet sanction)

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [digests: :string])
    {salt, digests} = load_digests(opts[:digests] || @digests_path)

    files = tracked_files()

    failures =
      Enum.concat([
        zero_site_content_hits(files, salt, digests),
        zero_site_path_hits(files, salt, digests),
        platform_name_hits(files)
      ])

    if failures == [] do
      Mix.shell().info("trinity.names: OK over #{length(files)} tracked files")
    else
      Enum.each(failures, &Mix.shell().error("FAIL #{&1}"))
      Mix.raise("trinity.names: #{length(failures)} violation(s)")
    end
  end

  @doc "Downcase, then split on every run of non-alphanumeric characters."
  @spec tokenise(String.t()) :: [String.t()]
  def tokenise(text) do
    text |> String.downcase() |> String.split(~r/[^a-z0-9]+/u, trim: true)
  end

  @doc "Salted SHA-256 of one token, lowercase hex."
  @spec digest(String.t(), String.t()) :: String.t()
  def digest(salt, token), do: :crypto.hash(:sha256, salt <> token) |> Base.encode16(case: :lower)

  defp load_digests(path) do
    lines = path |> File.read!() |> String.split("\n", trim: true)
    salt = lines |> Enum.find_value(fn l -> match_prefix(l, "salt ") end)
    digests = lines |> Enum.flat_map(fn l -> List.wrap(match_prefix(l, "digest ")) end) |> MapSet.new()
    salt || Mix.raise("#{path}: no salt line")
    {salt, digests}
  end

  defp match_prefix(line, prefix) do
    case String.split(line, prefix, parts: 2) do
      ["", rest] -> String.trim(rest)
      _ -> nil
    end
  end

  defp tracked_files do
    {out, 0} = System.cmd("git", ["ls-files"])
    out |> String.split("\n", trim: true) |> Enum.filter(&File.regular?/1)
  end

  defp zero_site_content_hits(files, salt, digests) do
    for path <- files,
        path != @digests_path,
        {line, n} <- numbered_lines(path),
        token <- tokenise(line),
        MapSet.member?(digests, digest(salt, token)),
        do: "#{path}:#{n}: forbidden name (zero permitted sites)"
  end

  defp zero_site_path_hits(files, salt, digests) do
    for path <- files,
        token <- tokenise(path),
        MapSet.member?(digests, digest(salt, token)),
        do: "#{path}: forbidden name in a PATH (zero permitted sites)"
  end

  defp platform_name_hits(files) do
    permitted = permitted_line_range()

    for path <- files,
        {line, n} <- numbered_lines(path),
        Enum.any?(@platform_names, &String.contains?(String.downcase(line), &1)),
        not permitted?(path, n, permitted),
        do: "#{path}:#{n}: platform name outside the approved section"
  end

  defp permitted?(@permitted_file, n, {lo, hi}) when is_integer(lo) and is_integer(hi),
    do: n > lo and n < hi

  defp permitted?(_, _, _), do: false

  defp permitted_line_range do
    lines = @permitted_file |> File.read!() |> String.split("\n")
    lo = Enum.find_index(lines, &(String.trim(&1) == @permitted_begin))
    hi = Enum.find_index(lines, &(String.trim(&1) == @permitted_end))

    if is_nil(lo) or is_nil(hi) or hi <= lo do
      Mix.raise(
        "#{@permitted_file}: the approved section is missing. Expected the heading " <>
          "#{inspect(@permitted_begin)} followed later by #{inspect(@permitted_end)}. " <>
          "The section is located by heading text, never by line number."
      )
    end

    {lo + 1, hi + 1}
  end

  defp numbered_lines(path) do
    case File.read(path) do
      {:ok, bin} ->
        if String.valid?(bin), do: bin |> String.split("\n") |> Enum.with_index(1), else: []

      _ ->
        []
    end
  end
end
