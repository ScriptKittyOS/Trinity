# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.Stig do
  @shortdoc "Derives the headless image's STIG applicability statement (slice 130, AC5)"

  @moduledoc """
  Turns OpenSCAP's evaluation of the headless image against the DISA STIG profile for RHEL 9
  (`scripts/stig_scan.sh`) into the image's STIG applicability statement, and fails when a rule has
  no disposition (slice 130, AC5; `docs/regulated/headless-image.md`).

      mix trinity.image.stig --results stig-results.xml [--dispositions PATH] [--out PATH]
                             [--image REF] [--digest IMAGE_ID]

  The population is every rule the profile selects, read from the results, never a list typed by
  hand. Each gets one disposition:

  * **met**: OpenSCAP's result is `pass`, or a row in `ci/headless/stig_dispositions.yaml` says
    how the image meets it otherwise;
  * **not applicable**: OpenSCAP's result is `notapplicable`, and the reason is the rule's own
    applicability condition (its platforms, from the guide), or a row gives one;
  * **the deployment's**: a row says what the deployment does and why the image cannot.

  A rule OpenSCAP reports any other way (`fail`, `notchecked`, `error`, ...) with no row fails the
  check; so does a row for a rule that no longer needs one, so the file cannot keep a disposition
  for something that changed. This is a statement about one image; it is not a STIG compliance
  determination for any host, and the statement says so.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @compile {:no_warn_undefined, :xmerl_sax_parser}

  @dispositions "ci/headless/stig_dispositions.yaml"
  @values %{
    "met" => "met",
    "not_applicable" => "not applicable",
    "deployment" => "the deployment's"
  }

  @typedoc "One selected rule, as the results describe it."
  @type rule :: %{
          id: String.t(),
          title: String.t(),
          stig: [String.t()],
          platforms: [String.t()],
          severity: String.t(),
          result: String.t()
        }

  @typedoc "What the results file says about the scan itself."
  @type scan :: %{
          rules: [rule()],
          profile: String.t(),
          version: String.t(),
          scanner: String.t(),
          time: String.t()
        }

  @typedoc "A rule with its disposition and reason."
  @type disposed :: {rule(), String.t(), String.t()}

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          results: :string,
          dispositions: :string,
          out: :string,
          image: :string,
          digest: :string
        ]
      )

    path = opts[:results] || Mix.raise("usage: mix trinity.image.stig --results stig-results.xml")
    Mix.ensure_application!(:xmerl)
    scan = read_results(path)
    rows = read_rows(opts[:dispositions] || @dispositions)
    {disposed, violations} = dispose(scan.rules, rows)

    if out = opts[:out] do
      File.write!(
        out,
        statement(scan, disposed, violations, Keyword.take(opts, [:image, :digest]))
      )

      Mix.shell().info("trinity.image.stig: wrote #{out}")
    end

    counts =
      disposed
      |> Enum.frequencies_by(&elem(&1, 1))
      |> Enum.sort()
      |> Enum.map_join(", ", fn {d, n} -> "#{n} #{d}" end)

    Mix.shell().info(
      "trinity.image.stig: #{length(scan.rules)} rule(s) in #{scan.profile}: #{counts}"
    )

    case violations do
      [] ->
        Mix.shell().info("trinity.image.stig: OK, every rule has a disposition")

      found ->
        Enum.each(found, &Mix.shell().error("FAIL #{&1}"))
        Mix.raise("trinity.image.stig: #{length(found)} violation(s)")
    end
  end

  @doc """
  Gives every rule its disposition: automatic for `pass` and `notapplicable`, from `rows`
  otherwise. Returns the disposed rules and the violations: rules with none, rows for rules that
  need none or are not in the profile, and malformed rows.
  """
  @spec dispose([rule()], [map()]) :: {[disposed()], [String.t()]}
  def dispose(rules, rows) do
    {by_rule, row_problems} = index_rows(rows)
    results = Enum.map(rules, &dispose_rule(&1, by_rule[&1.id]))
    unknown = Map.keys(by_rule) -- Enum.map(rules, & &1.id)

    violations =
      Enum.concat([
        for({:error, v} <- results, do: v),
        for({:stale, rule} <- results, do: stale_message(rule)),
        for(id <- Enum.sort(unknown), do: unknown_message(id)),
        row_problems
      ])

    {for({:ok, d} <- results, do: d), violations}
  end

  defp dispose_rule(%{result: "pass"} = rule, nil), do: {:ok, {rule, "met", "OpenSCAP: pass"}}

  defp dispose_rule(%{result: "notapplicable"} = rule, nil),
    do: {:ok, {rule, "not applicable", applicability_reason(rule)}}

  defp dispose_rule(rule, nil),
    do:
      {:error, "AC5: #{label(rule)} is #{rule.result} and has no disposition in #{@dispositions}"}

  defp dispose_rule(%{result: result} = rule, _row) when result in ["pass", "notapplicable"],
    do: {:stale, rule}

  defp dispose_rule(rule, row),
    do: {:ok, {rule, @values[row["disposition"]], String.trim(row["reason"])}}

  defp stale_message(rule),
    do: "AC5: #{label(rule)} is #{rule.result} now; remove its row from #{@dispositions}"

  defp unknown_message(id),
    do: "AC5: #{@dispositions} disposes of #{id}, which the profile does not select"

  defp index_rows(rows), do: Enum.reduce(rows, {%{}, []}, &index_row/2)

  defp index_row(row, {acc, problems}) do
    case row_problems(row) do
      [] ->
        dupes =
          for id <- row["rules"],
              Map.has_key?(acc, id),
              do: "AC5: #{id} has more than one disposition"

        {Enum.reduce(row["rules"], acc, &Map.put(&2, &1, row)), problems ++ dupes}

      found ->
        {acc,
         problems ++
           Enum.map(found, &"AC5: malformed disposition row #{inspect(row["rules"])}: #{&1}")}
    end
  end

  defp row_problems(row) when is_map(row) do
    Enum.concat([
      if(is_list(row["rules"]) and row["rules"] != [] and Enum.all?(row["rules"], &is_binary/1),
        do: [],
        else: ["needs a list of rule ids"]
      ),
      if(Map.has_key?(@values, row["disposition"]),
        do: [],
        else: ["disposition must be met, not_applicable or deployment"]
      ),
      if(is_binary(row["reason"]) and String.trim(row["reason"]) != "",
        do: [],
        else: ["needs a reason"]
      )
    ])
  end

  defp row_problems(_), do: ["is not a mapping"]

  @doc "The reason OpenSCAP's own applicability check gives for a rule it found not applicable."
  @spec applicability_reason(rule()) :: String.t()
  def applicability_reason(%{platforms: []}), do: "OpenSCAP: notapplicable"

  def applicability_reason(%{platforms: platforms}) do
    verb = if length(platforms) == 1, do: "holds", else: "hold"

    "OpenSCAP: notapplicable; the rule applies only where " <>
      Enum.map_join(platforms, " and ", &String.trim_leading(&1, "#")) <> " " <> verb
  end

  defp label(rule) do
    case rule.stig do
      [] -> rule.id
      ids -> "#{Enum.join(ids, ", ")} (#{rule.id})"
    end
  end

  # Results -------------------------------------------------------------------------------------

  @doc """
  The selected rules of an XCCDF results file, with their titles, DISA STIG identifiers,
  applicability platforms (their own and their groups') and results, read as a stream.
  """
  @spec read_results(Path.t()) :: scan()
  def read_results(path) do
    {:ok, state, _rest} =
      :xmerl_sax_parser.file(String.to_charlist(path),
        event_fun: &event/3,
        event_state: %{
          stack: [],
          holders: [],
          rules: %{},
          text: nil,
          result_id: nil,
          results: [],
          test: %{},
          in_test: false
        }
      )

    rules =
      for {id, result} <- Enum.reverse(state.results), result != "notselected" do
        info = Map.get(state.rules, id, %{title: "", stig: [], platforms: [], severity: ""})
        Map.merge(info, %{id: id, result: result})
      end

    Map.merge(%{rules: rules, profile: "", version: "", scanner: "", time: ""}, state.test)
  end

  defp event({:startElement, _, name, _, attrs}, _loc, state),
    do: start(to_string(name), attributes(attrs), state)

  defp event({:endElement, _, name, _}, _loc, state), do: finish(to_string(name), state)

  defp event({:characters, chars}, _loc, %{text: text} = state) when is_binary(text),
    do: %{state | text: text <> to_string(chars)}

  defp event(_event, _loc, state), do: state

  defp attributes(attrs),
    do: Map.new(attrs, fn {_, _, name, value} -> {to_string(name), to_string(value)} end)

  defp start("TestResult", attrs, state) do
    test =
      Map.merge(state.test, %{version: attrs["version"] || "", time: attrs["end-time"] || ""})

    push(%{state | in_test: true, test: test}, "TestResult")
  end

  defp start("profile", attrs, %{in_test: true} = state),
    do: push(put_in(state.test[:profile], attrs["idref"] || ""), "profile")

  defp start("fact", %{"name" => "urn:xccdf:fact:scanner:version"}, %{in_test: true} = state),
    do: push(%{state | text: ""}, "fact-version")

  defp start("rule-result", attrs, %{in_test: true} = state),
    do: push(%{state | result_id: attrs["idref"]}, "rule-result")

  defp start("result", _attrs, %{in_test: true} = state), do: push(%{state | text: ""}, "result")

  defp start(kind, attrs, %{in_test: false} = state) when kind in ["Group", "Rule"] do
    holder = %{
      kind: kind,
      id: attrs["id"],
      platforms: [],
      title: "",
      stig: [],
      severity: attrs["severity"] || ""
    }

    push(%{state | holders: [holder | state.holders]}, kind)
  end

  defp start(
         "platform",
         %{"idref" => idref},
         %{in_test: false, holders: [holder | rest]} = state
       ),
       do:
         push(
           %{state | holders: [%{holder | platforms: holder.platforms ++ [idref]} | rest]},
           "platform"
         )

  defp start(
         name,
         _attrs,
         %{in_test: false, holders: [%{kind: "Rule"} | _], stack: [parent | _]} = state
       )
       when name in ["title", "reference"] and parent == "Rule",
       do: push(%{state | text: ""}, name)

  defp start(name, _attrs, state), do: push(state, name)

  defp push(state, name), do: %{state | stack: [name | state.stack]}

  defp finish(_name, %{stack: [top | rest]} = state), do: close(top, %{state | stack: rest})

  defp close("TestResult", state), do: %{state | in_test: false}

  defp close("fact-version", state),
    do: %{state | text: nil, test: Map.put(state.test, :scanner, state.text)}

  defp close("result", state),
    do: %{
      state
      | text: nil,
        results: [{state.result_id, String.trim(state.text)} | state.results]
    }

  defp close("title", %{holders: [rule | rest], text: text} = state) when is_binary(text),
    do: %{state | text: nil, holders: [%{rule | title: String.trim(text)} | rest]}

  defp close("reference", %{holders: [rule | rest], text: text} = state) when is_binary(text) do
    id = String.trim(text)
    stig = if id =~ ~r/^RHEL-09-\d+$/, do: rule.stig ++ [id], else: rule.stig
    %{state | text: nil, holders: [%{rule | stig: stig} | rest]}
  end

  defp close("Rule", %{holders: [rule | groups]} = state) do
    inherited = groups |> Enum.reverse() |> Enum.flat_map(& &1.platforms)
    platforms = Enum.uniq(inherited ++ rule.platforms)
    info = %{title: rule.title, stig: rule.stig, platforms: platforms, severity: rule.severity}
    %{state | holders: groups, rules: Map.put(state.rules, rule.id, info)}
  end

  defp close("Group", %{holders: [_ | groups]} = state), do: %{state | holders: groups}
  defp close(_name, state), do: state

  # The statement -------------------------------------------------------------------------------

  @doc "The applicability statement as Markdown, one row per selected rule."
  @spec statement(scan(), [disposed()], [String.t()], keyword()) :: String.t()
  def statement(scan, disposed, violations, opts \\ []) do
    counts = disposed |> Enum.frequencies_by(&elem(&1, 1))

    results =
      scan.rules
      |> Enum.frequencies_by(& &1.result)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {r, n} -> "#{n} #{r}" end)

    rows =
      disposed
      |> Enum.sort_by(fn {rule, _, _} -> {List.first(rule.stig) || "~", rule.id} end)
      |> Enum.map(fn {rule, disposition, reason} ->
        "| #{Enum.join(rule.stig, ", ")} | #{cell(rule.title)} | #{rule.severity} | #{rule.result} | #{disposition} | #{cell(reason)} |"
      end)

    """
    <!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
    <!-- SPDX-License-Identifier: Apache-2.0 -->
    # STIG applicability statement: the Trinity headless image

    **Generated, not written.** `mix trinity.image.stig` derived this file from OpenSCAP's evaluation of
    one built image; edit `ci/headless/stig_dispositions.yaml` and regenerate, never this file.

    **This is a statement about an image, not a compliance determination.** It says, for each rule of
    the DISA STIG profile for RHEL 9 that the SCAP Security Guide selects, whether this container image
    meets it, why it does not apply to a container image, or why it belongs to the deployment that runs
    the image. It is not a STIG compliance determination for any host, and it is not an authorization.

    | | |
    |---|---|
    | Image | #{opts[:image] || "(not given)"} |
    | Image ID | #{opts[:digest] || "(not given)"} |
    | Profile | `#{scan.profile}` |
    | SCAP Security Guide | #{scan.version} (`ssg-rhel9-ds.xml`) |
    | Scanner | OpenSCAP #{scan.scanner} |
    | Evaluated | #{scan.time} |
    | Deriving commands | `scripts/stig_scan.sh IMAGE OUT`, then `mix trinity.image.stig --results OUT/stig-results.xml --out PATH --image IMAGE --digest IMAGE_ID` |

    #{length(scan.rules)} rules selected. OpenSCAP: #{results}. Dispositions: #{counts["met"] || 0} met,
    #{counts["not applicable"] || 0} not applicable, #{counts["the deployment's"] || 0} the deployment's,
    #{length(violations)} without one.

    #{if violations == [], do: "Every rule has a disposition.", else: "**Rules without a disposition, or rows that need attention:**\n\n" <> Enum.map_join(violations, "\n", &"* #{&1}")}

    | STIG ID | Rule | Severity | OpenSCAP | Disposition | Reason |
    |---|---|---|---|---|---|
    #{Enum.join(rows, "\n")}
    """
  end

  defp cell(text), do: text |> String.replace("|", "\\|") |> String.replace(~r/\s+/, " ")

  defp read_rows(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} -> (data || %{}) |> Map.get("dispositions", []) |> List.wrap()
      {:error, _} -> Mix.raise("cannot read #{path}")
    end
  end
end
