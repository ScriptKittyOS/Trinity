# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.ControlMappingTest do
  @moduledoc """
  Slice 132: `docs/regulated/control-mapping.md` cannot drift from the tree, from NIST's
  catalogues, from the responsibility matrix or from the standards register.

  A mapping of mechanisms to controls is worth exactly as much as its agreement with the things it
  names, and that agreement decays silently: a file moves, a test is renamed, a register row is
  downgraded, and the document goes on saying what it said. `Trinity.Receipts.SchemeMappingTest`
  holds `docs/receipt-scheme-mapping.md` to the payload it describes; this holds the control mapping
  to the tree in the same way, with the document's own rows as the population.

  Every rule here is tested twice: against the real document, where it must find nothing, and
  against a copy of the real document with one violation planted, where it must find exactly that.
  The second half is what makes the first worth reading.
  """
  use ExUnit.Case, async: true

  alias Trinity.Test.ControlMapping, as: CM

  @doc_path "docs/regulated/control-mapping.md"
  @crm_path "docs/regulated/customer-responsibility-matrix.md"
  @register_path "docs/09-standards-register.md"
  @sp800_53_path "test/support/fixtures/nist/sp800-53r5.tsv"
  @sp800_218_path "test/support/fixtures/nist/sp800-218.tsv"

  for path <- [@doc_path, @crm_path, @register_path, @sp800_53_path, @sp800_218_path] do
    @external_resource path
  end

  defp doc, do: File.read!(@doc_path)
  defp rows(text \\ doc()), do: CM.rows(text)
  defp sp800_53, do: @sp800_53_path |> File.read!() |> CM.catalogue()
  defp sp800_218, do: @sp800_218_path |> File.read!() |> CM.catalogue()
  defp crm, do: @crm_path |> File.read!() |> CM.crm()
  defp register, do: @register_path |> File.read!() |> CM.register()

  defp tracked do
    {out, 0} = System.cmd("git", ["ls-files"])
    out |> String.split("\n", trim: true) |> MapSet.new()
  end

  defp gate_steps, do: Mix.Project.config()[:aliases][:gate] |> Enum.map(&CM.gate_step/1)

  # How a check named in a row is found. A test by its literal name in its file; a Mix task by
  # Mix's own lookup, or as a step of the gate (Hex's tasks are an archive the suite does not load);
  # a function by loading its module.
  defp resolve do
    %{
      test_names: fn file ->
        case File.read(file) do
          {:ok, src} ->
            Regex.scan(~r/^\s*(?:test|property)\s+"((?:[^"\\]|\\.)*)"/m, src)
            |> Enum.map(fn [_, name] -> name end)

          {:error, _} ->
            :missing
        end
      end,
      mix_task?: fn task -> Mix.Task.get(task) != nil or task in gate_steps() end,
      function?: fn mod, fun, arity ->
        module = Module.concat([mod])

        Code.ensure_loaded?(module) and
          function_exported?(module, String.to_atom(fun), arity)
      end
    }
  end

  # Replace the first occurrence of `from` inside the row for `control` and return the document,
  # asserting the plant took, so a plant that silently changed nothing cannot pass for a red.
  defp plant(control, from, to) do
    text = doc()

    row =
      Regex.scan(~r/^\| `#{Regex.escape(control)}` \|.*$/m, text)
      |> Enum.map(&hd/1)
      |> Enum.find(&String.contains?(&1, from))

    assert row, "no #{control} row contains #{inspect(from)}"

    planted =
      String.replace(text, row, String.replace(row, from, to, global: false), global: false)

    assert planted != text, "the plant in #{control} changed nothing"
    planted
  end

  describe "the document is what this test reads" do
    test "both tables parse into rows, so no check below is vacuous" do
      rows = rows()
      assert Enum.count(rows, &(&1.table == :sp800_53)) > 40
      assert Enum.count(rows, &(&1.table == :sp800_218)) > 8
    end

    test "the catalogue fixtures are NIST's, by the source, commit and digest they record" do
      for {catalogue, url_part, count_kinds, count} <- [
            {sp800_53(), "SP800-53/rev5", ["control"], 1196},
            {sp800_218(), "SP800-218/ver1", ["practice", "task"], 61}
          ] do
        assert catalogue.header["source"] =~
                 "https://raw.githubusercontent.com/usnistgov/oscal-content/"

        assert catalogue.header["source"] =~ url_part
        assert catalogue.header["commit"] =~ ~r/^[0-9a-f]{40}$/
        assert catalogue.header["sha256"] =~ ~r/^[0-9a-f]{64}$/
        assert catalogue.header["source"] =~ catalogue.header["commit"]

        assert Enum.count(catalogue.ids, fn {_, {kind, _, _}} -> kind in count_kinds end) == count
      end

      assert map_size(sp800_53().families) == 20
      assert map_size(sp800_218().families) == 4
    end
  end

  describe "AC1: every row names the identifier, the mechanism, the path and the ownership" do
    test "the real document" do
      assert CM.shape_violations(rows()) == []
    end

    test "a planted ownership outside the three is refused" do
      planted = plant("AU-12", "| Trinity's |", "| compliant |")
      assert ["line " <> _ = v] = CM.shape_violations(rows(planted))
      assert v =~ ~s(ownership "compliant" is not one of)
    end
  end

  describe "the identifiers are NIST's" do
    test "every identifier in both tables is in its catalogue and not withdrawn" do
      assert CM.id_violations(rows(), sp800_53(), sp800_218()) == []
    end

    test "a planted control that does not exist is refused" do
      planted = plant("AU-12", "`AU-12`", "`AU-99`")
      assert [v] = CM.id_violations(rows(planted), sp800_53(), sp800_218())
      assert v =~ "AU-99 is not an identifier in NIST's SP 800-53 Rev. 5 catalogue"
    end

    test "a planted withdrawn control is refused, because a withdrawn control maps nothing" do
      planted = plant("AU-12", "`AU-12`", "`AC-2(10)`")
      assert [v] = CM.id_violations(rows(planted), sp800_53(), sp800_218())
      assert v =~ "AC-2(10) is withdrawn"
    end

    test "a planted practice SSDF 1.1 does not have is refused" do
      planted = plant("PW.8.2", "`PW.8.2`", "`PW.3.1`")
      assert [v] = CM.id_violations(rows(planted), sp800_53(), sp800_218())
      assert v =~ "PW.3.1 is not an identifier in NIST's SP 800-218 catalogue"
    end
  end

  describe "AC2: every path in every row exists" do
    test "the real document" do
      assert CM.path_violations(rows(), tracked()) == []
    end

    test "a planted moved path fails, naming it" do
      planted = plant("AU-12", "`lib/trinity/effects.ex`", "`lib/trinity/effects/membrane.ex`")
      assert [v] = CM.path_violations(rows(planted), tracked())
      assert v =~ "lib/trinity/effects/membrane.ex does not exist in this tree"
    end
  end

  describe "AC3: no row claims a control Trinity does not implement" do
    test "every Trinity's row names a check, and every check named exists" do
      assert CM.check_violations(rows(), resolve()) == []
    end

    test "a planted row naming a test that does not exist fails" do
      planted =
        plant(
          "AU-12",
          ~s("AC3: every gate decision and every effect yields a receipt),
          ~s("every effect yields a receipt, which nobody wrote)
        )

      assert [v] = CM.check_violations(rows(planted), resolve())
      assert v =~ "test/trinity/effects/membrane_test.exs has no test named"
    end

    test "a planted row naming a function that does not exist fails" do
      planted =
        plant(
          "AC-5",
          "`Trinity.Profile.check_authority/2`",
          "`Trinity.Profile.check_separation/2`"
        )

      assert [v] = CM.check_violations(rows(planted), resolve())
      assert v =~ "Trinity.Profile.check_separation/2 does not exist"
    end

    test "a planted Trinity's row with no check at all fails" do
      [row] = Regex.run(~r/^\| `AU-12` \|.*$/m, doc())

      [c, m, p, _checks, o, part, a] =
        row |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

      planted =
        String.replace(
          doc(),
          row,
          "| " <> Enum.join([c, m, p, "none", o, part, a], " | ") <> " |"
        )

      assert [v] = CM.check_violations(rows(planted), resolve())
      assert v =~ "a Trinity's row names no test or enforcer"
    end
  end

  describe "ownership agrees with the responsibility matrix, which is its authority" do
    test "the real document" do
      rows = rows()
      assert CM.ownership_violations(rows) == []
      assert CM.crm_violations(rows, crm()) == []
    end

    test "the matrix's rows are what this test reads, and their keys are unique" do
      keys = Enum.map(crm(), & &1.key)
      assert length(keys) > 30

      assert keys == Enum.uniq(keys),
             "two rows of the matrix share a first cell, so a citation is ambiguous"
    end

    test "a planted row claiming more than the matrix gives it fails" do
      planted = plant("SC-28", "| the deployment's |", "| shared |")
      assert [v] = CM.crm_violations(rows(planted), crm())
      assert v =~ "says shared, and the responsibility matrix's row"
    end

    test "a planted shared row that cites nothing for the deployment's part fails" do
      planted =
        plant("AU-8", ~s(Register "Trusted time for receipts": real-world dependency), "none")

      assert [v] = CM.ownership_violations(rows(planted))
      assert v =~ "cites neither the responsibility matrix nor a register row"
    end
  end

  describe "AC4: the document opens with what the mapping is not" do
    test "the real document" do
      assert CM.opening_violations(doc()) == []
    end

    test "nothing outside that opening claims compliance, satisfaction, certification or novelty, and there is no em dash" do
      assert CM.claim_violations(doc()) == []
    end

    test "a planted opening that drops the System Security Plan limit fails" do
      planted =
        String.replace(doc(), "not a System Security Plan", "a System Security Plan",
          global: false
        )

      assert planted != doc()
      assert [v] = CM.opening_violations(planted)
      assert v =~ "not a System Security Plan"
    end

    test "a planted claim of compliance in a row fails" do
      planted = plant("AU-12", "| Trinity's |", "| Trinity's, compliant |")
      assert [v | _] = CM.claim_violations(planted)
      assert v =~ ~s("compliant" outside the statement of limits)
    end
  end

  describe "AC5: nothing in the mapping contradicts the standards register" do
    test "the real document" do
      assert CM.register_violations(rows(), register()) == []
    end

    test "every register row naming an SP 800-53 control is cited by a row for that control" do
      cited = for row <- rows(), {key, _} <- row.register, do: {key, row.control}
      register_controls = CM.register_controls(register())

      assert register_controls != [],
             "no register row names an SP 800-53 control; this check has gone vacuous"

      assert register_controls -- cited == []
    end

    test "a planted row claiming Trinity's where the register records a real-world dependency fails" do
      planted = plant("AU-8", "| shared |", "| Trinity's |")
      violations = CM.register_violations(rows(planted), register())
      assert Enum.any?(violations, &(&1 =~ "records real-world dependency"))
    end

    test "a planted row upgrading the register's :unknown fails" do
      planted = plant("AU-10", ~s|(AU-10)": :unknown|, ~s|(AU-10)": tree property|)
      assert [v] = CM.register_violations(rows(planted), register())
      assert v =~ ~s(says the register records "tree property")
      assert v =~ ~s(states [":unknown"])
    end
  end

  describe "populations derive from the tree, and every member is cited" do
    test "every row of the responsibility matrix" do
      cited = Enum.flat_map(rows(), & &1.crm)
      assert CM.uncited(Enum.map(crm(), & &1.key), cited, "responsibility matrix row") == []
    end

    test "every refusal the regulated profile makes" do
      refusals =
        for {fun, arity} <- Trinity.Profile.__info__(:functions),
            String.starts_with?(Atom.to_string(fun), "check_"),
            do: "Trinity.Profile.#{fun}/#{arity}"

      assert length(refusals) >= 6
      assert CM.uncited(refusals, CM.cited_checks(rows()).funs, "regulated refusal") == []
    end

    test "every census in the tree" do
      {out, 0} = System.cmd("git", ["ls-files", "test/*census*_test.exs"])
      censuses = String.split(out, "\n", trim: true)
      assert length(censuses) >= 7
      assert CM.uncited(censuses, CM.cited_checks(rows()).tests, "census") == []
    end

    test "every step of the gate, against SP 800-218 or the steps that serve no practice" do
      ssdf = rows() |> Enum.filter(&(&1.table == :sp800_218)) |> CM.cited_checks()

      none =
        CM.listed(doc(), "## Gate steps that serve no practice")
        |> Enum.map(fn {_, s, _} -> CM.gate_step(s) end)

      steps = gate_steps()
      assert length(steps) >= 15

      assert CM.uncited(
               steps,
               MapSet.union(MapSet.union(ssdf.mix, ssdf.scripts), MapSet.new(none)),
               "gate step"
             ) ==
               []

      assert none -- steps == [], "a step listed as serving no practice is not a step of the gate"
    end

    test "a planted census the document does not cite is named" do
      assert ["census test/trinity/planted_census_test.exs is cited by no row"] =
               CM.uncited(
                 ["test/trinity/planted_census_test.exs"],
                 CM.cited_checks(rows()).tests,
                 "census"
               )
    end

    test "every SP 800-53 family has a row, or is listed with a reason" do
      covered =
        rows()
        |> Enum.filter(&(&1.table == :sp800_53))
        |> Enum.map(&(&1.control |> String.slice(0, 2)))

      listed = CM.listed(doc(), "## Families with no row")

      assert CM.coverage_violations(Map.keys(sp800_53().families), covered, listed, "family") ==
               []
    end

    test "every SP 800-218 practice has a row for it or a task of it, or is listed with a reason" do
      practices = for {id, {"practice", _, _}} <- sp800_218().ids, do: id

      covered =
        for row <- rows(),
            row.table == :sp800_218,
            practice <- practices,
            row.control == practice or String.starts_with?(row.control, practice <> "."),
            do: practice

      listed = CM.listed(doc(), "## Practices with no row")
      assert CM.coverage_violations(practices, covered, listed, "practice") == []
    end

    test "a planted family listed as having no row while it has one fails" do
      listed = [{1, "AU", "nothing here"}]

      assert ["line 1: family AU is listed as having no row, and has one"] =
               CM.coverage_violations(["AU"], ["AU"], listed, "family")
    end
  end
end
