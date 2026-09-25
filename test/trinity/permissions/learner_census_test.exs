# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.LearnerCensusTest do
  @moduledoc """
  Slice 042 AC2: nothing the learner produces reaches a pending approval.

  **This census is the reason the slice has the shape it has.** The connectome research report asked
  for a learned recommendation at the arbitration point; the anchoring, automation-bias and
  approval-fatigue literature says that is the one place it must not go. A decision recorded in a
  document is a decision somebody reverses in six months without noticing what it was for. This is
  the same decision, written so the build holds it.

  It is not behind a setting, either. A flag that could put a recommendation back on the approval
  card would be the harm with a delay.
  """
  use ExUnit.Case, async: true

  # The surface a pending approval is rendered through. `approval_card/1` takes exactly two
  # attributes, `approval` and `pattern`, which is what makes this checkable rather than hopeful.
  @approval_path ["lib/trinity_web/components/approval_components.ex"]
  @gate_path ["lib/trinity/permissions/gate.ex"]
  @planted "test/support/permissions/learner_on_approval_card.ex"

  # Two layers, and this tests the second. `Trinity.Permissions.Learner` is not exported from its
  # boundary, so a direct reference to it does not compile: the boundary compiler is the first line.
  # What it cannot see is the public facade, `Permissions.proposals/1`, which anything may call. This
  # census is about that call reaching the approval path.
  defp mentions_learner?(source) do
    source =~ "Permissions.Learner" or source =~ "proposals(" or source =~ "divergences("
  end

  defp population do
    {out, 0} = System.cmd("git", ["ls-files" | @approval_path ++ @gate_path ++ [@planted]])
    String.split(out, "\n", trim: true)
  end

  test "the population is what it claims to be" do
    files = population()
    assert @planted in files, "the planted violation is not tracked, so this census sees nothing"
    assert hd(@approval_path) in files
    assert hd(@gate_path) in files
  end

  test "only the planted file lets the learner near a pending approval" do
    offenders = for f <- population(), mentions_learner?(File.read!(f)), do: f

    assert offenders == [@planted],
           "#{inspect(offenders -- [@planted])} puts the learner on the path that renders or " <>
             "decides a pending approval. A recommendation shown before the owner forms their own " <>
             "view moves the decision, and this project's permission model rests on it not being " <>
             "moved"
  end

  test "the planted file really does annotate an approval, or this census proves nothing" do
    source = File.read!(@planted)
    assert mentions_learner?(source)
    assert source =~ "def hint"
    assert source =~ "you have chosen to"
  end

  describe "AC5: the learner reads and proposes, and writes nothing" do
    test "it never writes a rule, a policy or the effect catalogue itself" do
      source = File.read!("lib/trinity/permissions/learner.ex")

      # Call-shaped, with the parenthesis. The first version matched the bare name and flagged the
      # module's own docstring, which names `put_rule/1` to say who does write a rule. A census that
      # cannot tell a call from a sentence about a call trains people to reword their documentation.
      for forbidden <- [
            "put_rule(",
            "Repo.insert(",
            "Repo.insert!(",
            "Repo.update(",
            "Repo.delete(",
            "Catalog."
          ] do
        refute source =~ forbidden,
               "the learner calls #{forbidden}. It may propose a rule the owner could have written " <>
                 "by hand; writing one is the permissions context's job and accepting one is the " <>
                 "owner's"
      end

      assert source =~ "Repo.all(",
             "the learner reads nothing, so this test is asserting the absence of writes in a " <>
               "module that does not touch the database at all"
    end
  end
end
