# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.AibomTest do
  @moduledoc """
  Slice 131, AC7: the AI-BOM generator and the check that holds its profile, over a fixture
  shaped like slice 133's static model and slice 134's Tier 3 model
  (`test/support/fixtures/supply_chain/models.yaml`), and over the image's own models file.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Trinity.Image.Aibom

  @fixture "test/support/fixtures/supply_chain/models.yaml"
  @image_models "ci/headless/ai_models.yaml"
  @static "sentence-transformers/static-retrieval-mrl-en-v1"
  @weights "5990c1104963d8e2402854c80b9a8f8e3a490085c037f25ced63642f4578c520"

  defp models, do: Aibom.read_models!(@fixture)
  defp bom(models \\ models()), do: Aibom.bom(models, source: @fixture)
  defp static(models), do: Enum.find(models, &(&1["space"]["model_id"] == @static))

  defp update_static(fun) do
    Enum.map(models(), fn m -> if m["space"]["model_id"] == @static, do: fun.(m), else: m end)
  end

  defp component(bom, type, name),
    do: Enum.find(bom["components"], &(&1["type"] == type and &1["name"] == name))

  defp prop(component, name),
    do: Enum.find_value(component["properties"], &(&1["name"] == name && &1["value"]))

  describe "the fixture" do
    test "generates a CycloneDX 1.6 ML-BOM the check accepts" do
      bom = bom()
      assert Aibom.check(bom) == []
      assert bom["bomFormat"] == "CycloneDX" and bom["specVersion"] == "1.6"

      types = Enum.frequencies_by(bom["components"], & &1["type"])
      assert types == %{"machine-learning-model" => 2, "data" => 14}
    end

    test "the shipped model carries the weights SHA-256, its licence and the space" do
      model = component(bom(), "machine-learning-model", "static-retrieval-mrl-en-v1")

      assert model["group"] == "sentence-transformers"
      assert model["version"] == "f60985c706f192d45d218078e49e5a8b6f15283a"
      assert model["scope"] == "required"
      assert model["hashes"] == [%{"alg" => "SHA-256", "content" => @weights}]
      assert model["licenses"] == [%{"license" => %{"id" => "Apache-2.0"}}]
      assert prop(model, "trinity:delivery") == "shipped"
      assert prop(model, "trinity:legal-review") == "pending"

      manifest = prop(model, "trinity:space:manifest")
      assert Jcs.encode(Jason.decode!(manifest)) == manifest
      assert Jason.decode!(manifest)["weights_digest"] == @weights
      assert prop(model, "trinity:space:id") == Aibom.space_id(static(models())["space"])

      assert prop(model, "trinity:space:id") ==
               :crypto.hash(:sha256, manifest) |> Base.encode16(case: :lower)
    end

    test "every training dataset is a data component, MS MARCO with its terms quoted" do
      bom = bom()
      model = component(bom, "machine-learning-model", "static-retrieval-mrl-en-v1")
      refs = Enum.map(model["modelCard"]["modelParameters"]["datasets"], & &1["ref"])
      assert length(refs) == 13

      by_ref = Map.new(bom["components"], &{&1["bom-ref"], &1})
      assert Enum.all?(refs, &(by_ref[&1]["type"] == "data"))

      marco =
        component(
          bom,
          "data",
          "sentence-transformers/msmarco-co-condenser-margin-mse-sym-mnrl-mean-v1"
        )

      [%{"license" => licence}] = marco["licenses"]
      assert licence["name"] == "MS MARCO terms"
      refute Map.has_key?(licence, "id")
      assert licence["text"]["content"] =~ "non-commercial research purposes only"
    end

    test "a consideration names the risk, with the legal review's status as its mitigation" do
      model = component(bom(), "machine-learning-model", "static-retrieval-mrl-en-v1")
      [risk] = model["modelCard"]["considerations"]["ethicalConsiderations"]

      assert risk["name"] =~ "MS MARCO"

      assert risk["mitigationStrategy"] =~
               "Legal review of the licence and the training-data terms: pending"
    end

    test "the operator-pulled model is recorded as operator-accepted, never as shipped" do
      model = component(bom(), "machine-learning-model", "Qwen3-Embedding-0.6B")

      assert prop(model, "trinity:delivery") == "operator-accepted"
      assert model["scope"] == "optional"
      assert prop(model, "trinity:legal-review") == "operator"
    end

    test "the same models give the same bill, serial number included" do
      assert bom() == bom()
      assert bom()["serialNumber"] =~ ~r/\Aurn:uuid:[0-9a-f-]{36}\z/
    end
  end

  describe "AC7 red: the check refuses" do
    test "a model whose dataset list was removed (from the models file)" do
      models = update_static(&Map.delete(&1, "datasets"))

      assert Aibom.check(bom(models)) == [
               "model sentence-transformers/static-retrieval-mrl-en-v1: no training dataset is " <>
                 "listed (modelCard.modelParameters.datasets)"
             ]
    end

    test "a model whose dataset list was removed (from the bill itself)" do
      bom = bom()

      stripped =
        update_in(bom, ["components"], fn cs ->
          Enum.map(cs, fn
            %{"name" => "static-retrieval-mrl-en-v1"} = c ->
              update_in(c, ["modelCard", "modelParameters"], &Map.delete(&1, "datasets"))

            c ->
              c
          end)
        end)

      assert [msg] = Aibom.check(stripped)
      assert msg =~ "no training dataset is listed"
    end

    test "an empty dataset list" do
      assert [msg] = Aibom.check(bom(update_static(&Map.put(&1, "datasets", []))))
      assert msg =~ "no training dataset is listed"
    end

    test "a dataset with no licence and no quoted terms" do
      models =
        update_static(fn m ->
          update_in(m, ["datasets"], fn [first | rest] ->
            [Map.delete(first, "licence") | rest]
          end)
        end)

      assert [msg] = Aibom.check(bom(models))
      assert msg =~ "has no licence: an SPDX id, or a name with the terms quoted"
    end

    test "terms named but not quoted" do
      models =
        update_static(fn m ->
          update_in(m, ["datasets"], fn [first | rest] ->
            [put_in(first, ["licence"], %{"name" => "MS MARCO terms"}) | rest]
          end)
        end)

      assert [msg] = Aibom.check(bom(models))
      assert msg =~ "has no licence"
    end

    test "an unrecorded dataset licence once the legal review has passed" do
      models = update_static(&put_in(&1, ["legal_review", "status"], "passed"))
      found = Aibom.check(bom(models))

      assert length(found) == 11
      assert Enum.all?(found, &(&1 =~ "licence is unrecorded, but the legal review passed"))
    end

    test "a dataset reference that resolves to nothing" do
      bom = bom()

      broken =
        update_in(bom, ["components"], fn cs ->
          Enum.reject(cs, &(&1["name"] == "sentence-transformers/squad"))
        end)

      assert [msg] = Aibom.check(broken)
      assert msg =~ "resolves to no data component"
    end

    test "a shipped model with no weights hash, or a hash that is not the space's digest" do
      no_hash = update_static(&Map.delete(&1, "weights"))
      assert [msg] = Aibom.check(bom(no_hash))
      assert msg =~ "no SHA-256 of the weights the image carries"

      other = String.duplicate("ab", 32)
      wrong = update_static(&put_in(&1, ["weights", "sha256"], other))
      assert [msg] = Aibom.check(bom(wrong))
      assert msg =~ "is not the space's weights_digest"
    end

    test "an operator-accepted model claimed as required" do
      bom = bom()

      claimed =
        update_in(bom, ["components"], fn cs ->
          Enum.map(cs, fn
            %{"name" => "Qwen3-Embedding-0.6B"} = c -> Map.put(c, "scope", "required")
            c -> c
          end)
        end)

      assert [msg] = Aibom.check(claimed)
      assert msg =~ "an operator-accepted model is never shipped"
    end

    test "a delivery or a review status outside the vocabulary" do
      assert [msg] = Aibom.check(bom(update_static(&Map.put(&1, "delivery", "bundled"))))
      assert msg =~ ~s(delivery "bundled" is not one of)

      assert [msg] =
               Aibom.check(bom(update_static(&put_in(&1, ["legal_review", "status"], "ok"))))

      assert msg =~ ~s(legal review status "ok")
    end

    test "a model with no risk named" do
      assert [msg] = Aibom.check(bom(update_static(&Map.delete(&1, "risks"))))
      assert msg =~ "no consideration names a risk"
    end

    test "a model with no licence" do
      assert [msg] = Aibom.check(bom(update_static(&Map.delete(&1, "licence"))))
      assert msg =~ ": no licence"
    end

    test "a space manifest edited after its ID was computed" do
      bom = bom()

      edited =
        update_in(bom, ["components"], fn cs ->
          Enum.map(cs, fn
            %{"name" => "static-retrieval-mrl-en-v1"} = c ->
              update_in(c, ["properties"], fn ps ->
                Enum.map(ps, fn
                  %{"name" => "trinity:space:manifest", "value" => v} = p ->
                    %{p | "value" => String.replace(v, ~s("dim":256), ~s("dim":1024))}

                  p ->
                    p
                end)
              end)

            c ->
              c
          end)
        end)

      assert [msg] = Aibom.check(edited)
      assert msg =~ "trinity:space:id is not the SHA-256 of the space manifest"
    end

    test "a space missing one of slice 133's fourteen fields" do
      models = update_static(&update_in(&1, ["space"], fn s -> Map.delete(s, "num_ctx") end))
      assert [msg] = Aibom.check(bom(models))
      assert msg =~ "not slice 133's fourteen"
    end

    test "a document that is not CycloneDX 1.6" do
      found = Aibom.check(%{"bomFormat" => "SPDX", "components" => []})
      assert "bomFormat is not CycloneDX" in found
      assert "specVersion is not 1.6" in found
      assert "serialNumber is not a urn:uuid" in found
    end
  end

  describe "the image's own models file" do
    test "generates a bill the check accepts" do
      models = Aibom.read_models!(@image_models)
      bom = Aibom.bom(models, source: @image_models)
      assert Aibom.check(bom) == []
    end

    test "D7: no model is shipped before its legal review has passed" do
      assert Aibom.unreviewed_shipped(Aibom.read_models!(@image_models)) == []
    end

    test "D7's check finds a shipped model whose review is pending (planted)" do
      assert Aibom.unreviewed_shipped(models()) == [@static]
    end
  end

  describe "the task" do
    @describetag :tmp_dir

    test "writes a bill that --check then accepts", %{tmp_dir: dir} do
      out = Path.join(dir, "ai-bom.cdx.json")

      Mix.Tasks.Trinity.Image.Aibom.run([
        "--models",
        @fixture,
        "--out",
        out,
        "--image",
        "trinity-headless",
        "--digest",
        "sha256:" <> String.duplicate("0", 64)
      ])

      bom = out |> File.read!() |> Jason.decode!()

      assert bom["metadata"]["component"]["hashes"] == [
               %{"alg" => "SHA-256", "content" => String.duplicate("0", 64)}
             ]

      Mix.Tasks.Trinity.Image.Aibom.run(["--check", out])
    end

    test "--check refuses a bill without a dataset list", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.cdx.json")
      File.write!(path, Jason.encode!(bom(update_static(&Map.delete(&1, "datasets")))))

      assert_raise Mix.Error, ~r/1 violation/, fn ->
        Mix.Tasks.Trinity.Image.Aibom.run(["--check", path])
      end
    end

    test "refuses to write a bill that fails the check", %{tmp_dir: dir} do
      models = Path.join(dir, "models.yaml")
      out = Path.join(dir, "ai-bom.cdx.json")
      File.write!(models, File.read!(@fixture) |> String.replace("risks:", "unused_risks:"))

      assert_raise Mix.Error, ~r/violation/, fn ->
        Mix.Tasks.Trinity.Image.Aibom.run(["--models", models, "--out", out])
      end

      refute File.exists?(out)
    end
  end
end
