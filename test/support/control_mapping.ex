# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Test.ControlMapping do
  @moduledoc """
  Slice 132: reads `docs/regulated/control-mapping.md`, and the documents it defers to, and says
  what is wrong with it.

  Every function here is pure over text and over what the caller hands in (the tracked files, the
  catalogues, a resolver for checks). That is what lets `test/control_mapping_test.exs` run each
  planted violation against a modified copy of the real document as a permanent test, instead of
  editing the file and putting it back: a red that lives in the suite is a red that cannot quietly
  stop being one.

  Each `*_violations` function answers a list of sentences, empty when there is nothing wrong.
  A sentence names the row by its line and its identifier, so a failure says where to look.
  """

  @ownerships ["Trinity's", "shared", "the deployment's"]
  @statuses [":unknown", "not claimed", "real-world dependency", "tree property"]
  @opening "## What this mapping is not"

  @typedoc "One row of a mapping table."
  @type row :: %{
          line: pos_integer(),
          table: :sp800_53 | :sp800_218,
          cells: [String.t()],
          control: String.t() | nil,
          mechanism: String.t(),
          paths: [String.t()],
          checks: [check()],
          ownership: String.t(),
          part: String.t(),
          crm: [String.t()],
          register: [{String.t(), String.t()}],
          unparsed: [String.t()]
        }

  @typedoc "What a row's Check cell can name."
  @type check ::
          {:test, String.t(), String.t()}
          | {:mix, String.t()}
          | {:fun, String.t(), String.t(), non_neg_integer()}
          | {:script, String.t()}

  @doc "The ownership values the SLICE allows, strongest first."
  @spec ownerships() :: [String.t()]
  def ownerships, do: @ownerships

  @doc "The register's four statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  # ---------------------------------------------------------------------------------------------
  # The mapping document

  @doc """
  The rows of both mapping tables. A row is a line beginning `` | ` `` under a heading that begins
  `## SP 800-53` or `## SP 800-218`; anything else in the document is prose or another table.
  """
  @spec rows(String.t()) :: [row()]
  def rows(doc) do
    doc
    |> numbered()
    |> Enum.reduce({nil, []}, fn {line, n}, {section, acc} ->
      cond do
        String.starts_with?(line, "## ") ->
          {table_of(line), acc}

        section && String.starts_with?(line, "| `") ->
          {section, [parse_row(line, n, section) | acc]}

        true ->
          {section, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp table_of("## SP 800-53" <> _), do: :sp800_53
  defp table_of("## SP 800-218" <> _), do: :sp800_218
  defp table_of(_), do: nil

  defp parse_row(line, n, table) do
    cells = cells(line)
    base = %{line: n, table: table, cells: cells, unparsed: []}

    case cells do
      [control, mechanism, paths, checks, ownership, part, authority] ->
        {checks, bad_checks} = parse_checks(checks)
        {crm, register, bad_auth} = parse_authority(authority)

        Map.merge(base, %{
          control: backticked(control),
          mechanism: mechanism,
          paths: Regex.scan(~r/`([^`]+)`/, paths) |> Enum.map(fn [_, p] -> p end),
          checks: checks,
          ownership: ownership,
          part: part,
          crm: crm,
          register: register,
          unparsed: bad_checks ++ bad_auth
        })

      _ ->
        Map.merge(base, %{
          control: nil,
          mechanism: "",
          paths: [],
          checks: [],
          ownership: "",
          part: "",
          crm: [],
          register: []
        })
    end
  end

  defp backticked(cell) do
    case Regex.run(~r/^`([^`]+)`$/, cell) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp parse_checks("none"), do: {[], []}

  # Items are found by their shape, not by splitting on "; ", because a test's name may itself
  # contain "; " (slice 024's AC3 does). What is left once every item is removed must be nothing
  # but the separators, or the cell holds something this check does not read.
  defp parse_checks(cell) do
    items = Regex.scan(~r/`[^`]+`(?: "[^"]*")?/, cell) |> Enum.map(&hd/1)

    residue =
      items
      |> Enum.reduce(cell, &String.replace(&2, &1, "", global: false))
      |> String.replace(";", "")
      |> String.trim()

    leftover = if residue == "", do: [], else: ["check text #{inspect(residue)}"]

    Enum.reduce(items, {[], leftover}, fn item, {ok, bad} ->
      case parse_check(item) do
        nil -> {ok, bad ++ ["check #{inspect(item)}"]}
        check -> {ok ++ [check], bad}
      end
    end)
  end

  @doc "One item of a Check cell, or nil when it is none of the four forms."
  @spec parse_check(String.t()) :: check() | nil
  def parse_check(item) do
    cond do
      m = Regex.run(~r/^`(test\/[^`]+_test\.exs)` "([^"]+)"$/, item) ->
        [_, file, name] = m
        {:test, file, name}

      m = Regex.run(~r/^`mix ([a-z][a-z0-9_.]*)(?: [^`]*)?`$/, item) ->
        {:mix, Enum.at(m, 1)}

      m =
          Regex.run(
            ~r/^`((?:[A-Z][A-Za-z0-9_]*\.)*[A-Z][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*[?!]?)\/(\d+)`$/,
            item
          ) ->
        [_, mod, fun, arity] = m
        {:fun, mod, fun, String.to_integer(arity)}

      m = Regex.run(~r/^`(scripts\/[^`]+)`$/, item) ->
        {:script, Enum.at(m, 1)}

      true ->
        nil
    end
  end

  defp parse_authority("none"), do: {[], [], []}

  defp parse_authority(cell) do
    cell
    |> String.split("; ")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({[], [], []}, fn item, {crm, reg, bad} ->
      cond do
        m = Regex.run(~r/^CRM "([^"]+)"$/, item) ->
          {crm ++ [Enum.at(m, 1)], reg, bad}

        m = Regex.run(~r/^Register "([^"]+)": (.+)$/, item) ->
          {crm, reg ++ [{Enum.at(m, 1), Enum.at(m, 2)}], bad}

        true ->
          {crm, reg, bad ++ ["authority #{inspect(item)}"]}
      end
    end)
  end

  @doc "The first cell of every row of a two-column table under the given heading."
  @spec listed(String.t(), String.t()) :: [{pos_integer(), String.t(), String.t()}]
  def listed(doc, heading) do
    doc
    |> section(heading)
    |> Enum.filter(fn {line, _} -> String.starts_with?(line, "| `") end)
    |> Enum.map(fn {line, n} ->
      case cells(line) do
        [first, reason] -> {n, first |> String.trim("`"), reason}
        _ -> {n, line, ""}
      end
    end)
  end

  defp section(doc, heading) do
    doc
    |> numbered()
    |> Enum.drop_while(fn {line, _} -> String.trim(line) != heading end)
    |> Enum.drop(1)
    |> Enum.take_while(fn {line, _} -> not String.starts_with?(line, "## ") end)
  end

  # ---------------------------------------------------------------------------------------------
  # AC1: the row's shape

  @doc "AC1: every row has an identifier, a mechanism, a path and one of the three ownerships."
  @spec shape_violations([row()]) :: [String.t()]
  def shape_violations(rows), do: Enum.flat_map(rows, &shape/1)

  defp shape(%{cells: cells, line: n}) when length(cells) != 7,
    do: ["line #{n}: #{length(cells)} cells, expected 7"]

  defp shape(row) do
    at = "line #{row.line} #{row.control}"

    List.flatten([
      when_true(
        is_nil(row.control),
        "line #{row.line}: the identifier is not one backticked value"
      ),
      when_true(String.trim(row.mechanism) == "", "#{at}: no mechanism"),
      when_true(row.paths == [], "#{at}: no path in this tree"),
      when_true(
        row.ownership not in @ownerships,
        "#{at}: ownership #{inspect(row.ownership)} is not one of #{inspect(@ownerships)}"
      ),
      Enum.map(row.unparsed, &"#{at}: #{&1} is not a form this check reads")
    ])
  end

  defp when_true(true, sentence), do: [sentence]
  defp when_true(false, _sentence), do: []

  # ---------------------------------------------------------------------------------------------
  # The catalogues

  @doc """
  A fixture under `test/support/fixtures/nist/`: the header (lines beginning `# `) as a map, the
  families, and every identifier with its kind, status and family.
  """
  @spec catalogue(String.t()) :: %{header: map(), families: map(), ids: map()}
  def catalogue(text) do
    lines = String.split(text, "\n", trim: true)

    header =
      for "# " <> rest <- lines,
          [k, v] <- [String.split(rest, ": ", parts: 2)],
          into: %{},
          do: {k, v}

    entries =
      Enum.reject(lines, &String.starts_with?(&1, "#")) |> Enum.map(&String.split(&1, "\t"))

    %{
      header: header,
      families: for(["family", code, title] <- entries, into: %{}, do: {code, title}),
      ids: for([kind, id, status, family] <- entries, into: %{}, do: {id, {kind, status, family}})
    }
  end

  @doc "Every identifier is in its catalogue and not withdrawn."
  @spec id_violations([row()], map(), map()) :: [String.t()]
  def id_violations(rows, sp800_53, sp800_218) do
    Enum.flat_map(rows, fn
      %{control: nil} ->
        []

      %{table: table, control: id, line: n} ->
        catalogue = if table == :sp800_53, do: sp800_53, else: sp800_218
        name = if table == :sp800_53, do: "SP 800-53 Rev. 5", else: "SP 800-218"

        case Map.get(catalogue.ids, id) do
          nil -> ["line #{n}: #{id} is not an identifier in NIST's #{name} catalogue"]
          {_kind, "withdrawn", _} -> ["line #{n}: #{id} is withdrawn in NIST's #{name} catalogue"]
          {_kind, _status, _} -> []
        end
    end)
  end

  # ---------------------------------------------------------------------------------------------
  # AC2: paths

  @doc """
  AC2: every path a row names, in its Path cell or as a test file or script in its Check cell, is
  a tracked file, or a directory holding one. `tracked` is `git ls-files`.
  """
  @spec path_violations([row()], MapSet.t()) :: [String.t()]
  def path_violations(rows, tracked) do
    Enum.flat_map(rows, fn row ->
      named =
        row.paths ++
          for(check <- row.checks, path <- check_path(check), do: path)

      for path <- named, not tracked?(path, tracked) do
        "line #{row.line} #{row.control}: #{path} does not exist in this tree"
      end
    end)
  end

  defp check_path({:test, file, _}), do: [file]
  defp check_path({:script, path}), do: [path]
  defp check_path(_), do: []

  defp tracked?(path, tracked) do
    trimmed = String.trim_trailing(path, "/")

    MapSet.member?(tracked, trimmed) or
      Enum.any?(tracked, &String.starts_with?(&1, trimmed <> "/"))
  end

  # ---------------------------------------------------------------------------------------------
  # AC3: checks

  @doc """
  AC3: a `Trinity's` row names at least one check, and every check any row names exists.

  `resolve` carries three functions: `:test_names` (a file to the literal names of its tests, or
  `:missing`), `:mix_task?` and `:function?`.
  """
  @spec check_violations([row()], map()) :: [String.t()]
  def check_violations(rows, resolve) do
    Enum.flat_map(rows, fn row ->
      at = "line #{row.line} #{row.control}"

      none =
        if row.ownership == "Trinity's" and row.checks == [],
          do: ["#{at}: a Trinity's row names no test or enforcer"],
          else: []

      none ++ Enum.flat_map(row.checks, &missing_check(&1, at, resolve))
    end)
  end

  defp missing_check({:test, file, name}, at, resolve) do
    case resolve.test_names.(file) do
      :missing ->
        ["#{at}: #{file} does not exist"]

      names ->
        if name in names, do: [], else: ["#{at}: #{file} has no test named #{inspect(name)}"]
    end
  end

  defp missing_check({:mix, task}, at, resolve) do
    if resolve.mix_task?.(task), do: [], else: ["#{at}: there is no Mix task #{task}"]
  end

  defp missing_check({:fun, mod, fun, arity}, at, resolve) do
    if resolve.function?.(mod, fun, arity),
      do: [],
      else: ["#{at}: #{mod}.#{fun}/#{arity} does not exist"]
  end

  defp missing_check({:script, _path}, _at, _resolve), do: []

  # ---------------------------------------------------------------------------------------------
  # Ownership, and its authority

  @doc """
  The ownership cell agrees with the deployment's-part cell, and every row that gives the
  deployment a part cites what says so: a row of the responsibility matrix, or a register row
  whose status is `real-world dependency`.
  """
  @spec ownership_violations([row()]) :: [String.t()]
  def ownership_violations(rows), do: Enum.flat_map(rows, &ownership/1)

  defp ownership(%{ownership: "Trinity's", part: part} = row) do
    when_true(
      part != "none",
      "line #{row.line} #{row.control}: a Trinity's row gives the deployment a part; it is shared"
    )
  end

  defp ownership(%{ownership: o} = row) when o in ["shared", "the deployment's"] do
    at = "line #{row.line} #{row.control}"
    rwd? = Enum.any?(row.register, fn {_, s} -> s == "real-world dependency" end)

    when_true(row.part in ["", "none"], "#{at}: a #{o} row must say what the deployment supplies") ++
      when_true(
        row.crm == [] and not rwd?,
        "#{at}: a #{o} row cites neither the responsibility matrix nor a register row " <>
          "recording a real-world dependency, so nothing in the pack backs the deployment's part"
      )
  end

  defp ownership(_row), do: []

  # ---------------------------------------------------------------------------------------------
  # The customer responsibility matrix

  @doc """
  The responsibility matrix's rows, keyed by their first cell, each with the ownership its three
  cells imply: software cell beginning `No` or **NOT IN TREE** is `the deployment's`; beginning
  **Yes** with `No` for both customer and host is `Trinity's`; anything else is `shared`.
  """
  @spec crm(String.t()) :: [
          %{key: String.t(), section: String.t(), derived: String.t(), line: pos_integer()}
        ]
  def crm(text) do
    text
    |> numbered()
    |> Enum.reduce({nil, []}, fn {line, n}, {section, acc} ->
      cond do
        String.starts_with?(line, "## ") ->
          {String.trim_leading(line, "## "), acc}

        String.starts_with?(line, "| ") and section != nil ->
          {section, crm_line(cells(line), section, n) ++ acc}

        true ->
          {section, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp crm_line(["Control" | _], _section, _n), do: []

  defp crm_line([key, software, customer, host], section, n),
    do: [crm_row(key, section, software, customer, host, n)]

  defp crm_line(_cells, _section, _n), do: []

  defp crm_row(key, section, software, customer, host, n) do
    none? = software =~ ~r/^(\*\*)?(No\b|NOT IN TREE)/
    full? = software =~ ~r/^\*\*Yes\b/
    deployment? = customer != "No" or host != "No"

    derived =
      cond do
        none? -> "the deployment's"
        full? and not deployment? -> "Trinity's"
        true -> "shared"
      end

    %{key: key, section: section, derived: derived, line: n}
  end

  @doc "Every matrix row a mapping row cites exists, and the mapping's ownership is the matrix's."
  @spec crm_violations([row()], list()) :: [String.t()]
  def crm_violations(rows, crm) do
    by_key = Map.new(crm, &{&1.key, &1})

    for row <- rows, key <- row.crm, reduce: [] do
      acc ->
        at = "line #{row.line} #{row.control}"

        case Map.get(by_key, key) do
          nil ->
            acc ++ ["#{at}: the responsibility matrix has no row #{inspect(key)}"]

          %{derived: derived} when derived != row.ownership ->
            acc ++
              [
                "#{at}: says #{row.ownership}, and the responsibility matrix's row #{inspect(key)} " <>
                  "says #{derived}. The matrix is the authority for ownership"
              ]

          _ ->
            acc
        end
    end
  end

  # ---------------------------------------------------------------------------------------------
  # AC5: the standards register

  @doc """
  The register's rows, keyed by their first cell, each with the statuses its status cell states
  (any of `#{inspect(@statuses)}`).
  """
  @spec register(String.t()) :: [%{key: String.t(), statuses: [String.t()], line: pos_integer()}]
  def register(text) do
    text
    |> numbered()
    |> Enum.reduce({nil, []}, fn {line, n}, {status_at, acc} ->
      cond do
        not String.starts_with?(line, "|") ->
          {nil, acc}

        line =~ ~r/^\|[-|: ]+\|$/ ->
          {status_at, acc}

        is_nil(status_at) ->
          {Enum.find_index(cells(line), &(&1 == "Status")), acc}

        true ->
          cells = cells(line)
          status = Enum.at(cells, status_at, "")
          found = Enum.filter(@statuses, &String.contains?(status, &1))
          {status_at, [%{key: hd(cells), statuses: found, line: n} | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc """
  AC5: a row citing the register repeats a status that register row states, and claims no more:
  a row citing `real-world dependency` or `not claimed` cannot be `Trinity's`.
  """
  @spec register_violations([row()], list()) :: [String.t()]
  def register_violations(rows, register) do
    by_key = Map.new(register, &{&1.key, &1})

    for row <- rows, {key, stated} <- row.register, reduce: [] do
      acc ->
        at = "line #{row.line} #{row.control}"

        acc ++
          case Map.get(by_key, key) do
            nil ->
              ["#{at}: the standards register has no row #{inspect(key)}"]

            %{statuses: statuses} ->
              List.flatten([
                if(stated in statuses,
                  do: [],
                  else: [
                    "#{at}: says the register records #{inspect(stated)} for #{inspect(key)}; " <>
                      "the register's status cell states #{inspect(statuses)}"
                  ]
                ),
                if(
                  stated in ["real-world dependency", "not claimed"] and
                    row.ownership == "Trinity's",
                  do: [
                    "#{at}: the register records #{stated} for #{inspect(key)}, and the row says " <>
                      "Trinity's, which claims more than the register does"
                  ],
                  else: []
                )
              ])
          end
    end
  end

  @doc "The SP 800-53 identifiers the register names in a row's first cell, with that row's key."
  @spec register_controls(list()) :: [{String.t(), String.t()}]
  def register_controls(register) do
    for %{key: key} <- register,
        String.contains?(key, "800-53"),
        [_, id] <- Regex.scan(~r/\b([A-Z]{2}-\d+(?:\(\d+\))?)/, key),
        do: {key, id}
  end

  # ---------------------------------------------------------------------------------------------
  # Populations

  @doc "Members of a population that no row cites. `cited` is the set the rows name."
  @spec uncited([String.t()], Enumerable.t(), String.t()) :: [String.t()]
  def uncited(population, cited, what) do
    cited = MapSet.new(cited)

    for member <- population,
        not MapSet.member?(cited, member),
        do: "#{what} #{member} is cited by no row"
  end

  @doc "What a set of rows names as checks, in the form a population is compared in."
  @spec cited_checks([row()]) :: %{
          tests: MapSet.t(),
          mix: MapSet.t(),
          funs: MapSet.t(),
          scripts: MapSet.t()
        }
  def cited_checks(rows) do
    checks = Enum.flat_map(rows, & &1.checks)

    %{
      tests: for({:test, file, _} <- checks, into: MapSet.new(), do: file),
      mix: for({:mix, task} <- checks, into: MapSet.new(), do: task),
      funs: for({:fun, m, f, a} <- checks, into: MapSet.new(), do: "#{m}.#{f}/#{a}"),
      scripts: for({:script, p} <- checks, into: MapSet.new(), do: p)
    }
  end

  @doc """
  A step of the `gate` alias as the name a row cites it by: the Mix task, or the script's path.
  `cmd env ERL_AFLAGS= mix hex.audit` is `hex.audit`; `cmd env ERL_AFLAGS= ./scripts/prod_check.sh`
  is `scripts/prod_check.sh`.
  """
  @spec gate_step(String.t()) :: String.t()
  def gate_step(step) do
    words =
      step |> String.split(" ", trim: true) |> Enum.reject(&(&1 in ["cmd", "env", "ERL_AFLAGS="]))

    case words do
      ["mix", task | _] -> task
      ["./" <> script | _] -> script
      [task | _] -> task
    end
  end

  @doc """
  Every family (SP 800-53) or practice (SP 800-218) in the catalogue has a row, or is listed under
  "no row" with a reason; and nothing listed there also has a row, which would contradict it.
  """
  @spec coverage_violations(
          [String.t()],
          [String.t()],
          [{pos_integer(), String.t(), String.t()}],
          String.t()
        ) ::
          [String.t()]
  def coverage_violations(population, covered, listed, what) do
    covered = MapSet.new(covered)
    listed_ids = MapSet.new(listed, fn {_, id, _} -> id end)

    List.flatten([
      for(
        id <- population,
        not MapSet.member?(covered, id),
        not MapSet.member?(listed_ids, id),
        do: "#{what} #{id} has no row and is not listed with a reason"
      ),
      for(
        {n, id, reason} <- listed,
        String.trim(reason) == "",
        do: "line #{n}: #{what} #{id} is listed with no reason"
      ),
      for(
        {n, id, _} <- listed,
        MapSet.member?(covered, id),
        do: "line #{n}: #{what} #{id} is listed as having no row, and has one"
      ),
      for(
        {n, id, _} <- listed,
        id not in population,
        do: "line #{n}: #{id} is not a #{what} in the catalogue"
      )
    ])
  end

  # ---------------------------------------------------------------------------------------------
  # AC4: what the document says about itself

  @required_limits [
    {~r/not an assessment/i, "not an assessment"},
    {~r/not an authori[sz]ation to operate/i, "not an authorization to operate (ATO)"},
    {~r/not a System Security Plan/i, "not a System Security Plan"},
    {~r/not a claim that any baseline is met/i, "not a claim that any baseline is met"}
  ]

  @forbidden ~r/\b(compliant|compliance|complies|satisf(?:y|ies|ied)|certified|accredited|novel)\b/i

  @doc """
  AC4: the document's first section is #{inspect(@opening)}, it comes before any table, and it
  says each of the four limits.
  """
  @spec opening_violations(String.t()) :: [String.t()]
  def opening_violations(doc) do
    lines = numbered(doc)
    first_heading = Enum.find(lines, fn {l, _} -> String.starts_with?(l, "## ") end)
    first_table = Enum.find(lines, fn {l, _} -> String.starts_with?(l, "| ") end)
    opening = section(doc, @opening) |> Enum.map_join("\n", &elem(&1, 0))

    List.flatten([
      case first_heading do
        {@opening, _} ->
          []

        other ->
          ["the first section is #{inspect(other && elem(other, 0))}, not #{inspect(@opening)}"]
      end,
      case {first_heading, first_table} do
        {{_, h}, {_, t}} when t < h ->
          ["a table (line #{t}) comes before the statement of limits"]

        _ ->
          []
      end,
      for(
        {pattern, says} <- @required_limits,
        not Regex.match?(pattern, opening),
        do: "the opening section does not say the mapping is #{says}"
      )
    ])
  end

  @doc """
  Outside the opening section, which says what the mapping is not, the document claims nothing a
  mapping cannot: no compliance, satisfaction, certification, accreditation or novelty. And no em
  dash anywhere, which is this project's writing rule.
  """
  @spec claim_violations(String.t()) :: [String.t()]
  def claim_violations(doc) do
    opening = section(doc, @opening) |> MapSet.new(&elem(&1, 1))

    for {line, n} <- numbered(doc), reduce: [] do
      acc ->
        words =
          if MapSet.member?(opening, n),
            do: [],
            else: Regex.scan(@forbidden, line) |> Enum.map(&hd/1)

        dash = if String.contains?(line, "—"), do: ["line #{n}: an em dash"], else: []

        acc ++
          Enum.map(words, &"line #{n}: #{inspect(&1)} outside the statement of limits") ++ dash
    end
  end

  # ---------------------------------------------------------------------------------------------

  defp cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp numbered(text), do: text |> String.split("\n") |> Enum.with_index(1)
end
