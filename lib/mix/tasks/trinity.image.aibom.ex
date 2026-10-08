# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.Aibom do
  @shortdoc "Writes the headless image's AI-BOM (CycloneDX ML-BOM), or checks one (slice 131, AC7)"

  @moduledoc """
  The image's AI bill of materials: a CycloneDX 1.6 document with one `machine-learning-model`
  component for each model the image carries, from `ci/headless/ai_models.yaml`
  (`docs/regulated/image-verify.md`).

      mix trinity.image.aibom --out ai-bom.cdx.json [--models PATH] [--image NAME] [--digest sha256:HEX]
      mix trinity.image.aibom --check ai-bom.cdx.json

  Writing checks what it wrote, so a bill that would fail the check is never written.

  **What a model component carries.** The weights file's SHA-256 as the component hash; the
  model's licence; each training dataset as a `data` component with its licence, or, where a
  dataset's terms have no SPDX identifier (MS MARCO's "non-commercial research purposes only"),
  the terms quoted as the licence text; `modelCard.considerations` naming each risk, with the
  legal review's status as its mitigation; and the embedding space it defines, as two
  properties: slice 133's `Trinity.Memory.Space` manifest in RFC 8785 canonical JSON
  (`trinity:space:manifest`) and the space ID, which is the SHA-256 of exactly those bytes.

  **What the check refuses**, beyond what CycloneDX's own schema requires (its schema makes the
  dataset list optional, so it cannot be what holds AC7): a model with no SHA-256, no licence or
  no dataset; a dataset reference that resolves to no `data` component, or one with no licence,
  no SPDX id and no quoted terms; a model with no risk or no legal review status; a delivery other
  than `shipped` or `operator-accepted`, or an operator-accepted model claimed as required (it is
  never shipped: the operator pulled it); a dataset licence left `unrecorded` once the legal
  review has passed; a space manifest that is not the fourteen fields in canonical form, or whose
  SHA-256 is not the recorded space ID; and a hash that is not the space's `weights_digest`.

  The space ID is SHA-256 over the RFC 8785 canonical JSON of the manifest, as
  `Trinity.Memory.Space.id/1` computes it (slice 133). Until that slice is merged this module
  carries the same computation and the same field list.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @models "ci/headless/ai_models.yaml"
  @spec_version "1.6"
  @deliveries ~w(shipped operator-accepted)
  @reviews ~w(pending passed refused operator)
  @unrecorded "unrecorded"
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @serial ~r/\Aurn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # Slice 133's identity fields (`Trinity.Memory.Space.identity_fields/0`), in its order.
  @space_fields ~w(model_id revision weights_digest tokenizer_digest dim pooling normalisation
                   quantization query_prompt document_prompt max_input runtime locality num_ctx)

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [out: :string, models: :string, image: :string, digest: :string, check: :string]
      )

    case opts[:check] do
      nil -> write(opts)
      path -> check_file!(path)
    end
  end

  defp write(opts) do
    out = opts[:out] || Mix.raise("usage: mix trinity.image.aibom --out FILE | --check FILE")
    path = opts[:models] || @models
    bom = path |> read_models!() |> bom(image: opts[:image], digest: opts[:digest], source: path)

    case check(bom) do
      [] ->
        File.write!(out, Jason.encode_to_iodata!(bom, pretty: true))
        n = Enum.count(bom["components"], &(&1["type"] == "machine-learning-model"))
        Mix.shell().info("trinity.image.aibom: #{out} written, #{n} model(s) from #{path}")

      found ->
        fail!(found)
    end
  end

  defp check_file!(path) do
    bom = path |> File.read!() |> Jason.decode!()

    case check(bom) do
      [] -> Mix.shell().info("trinity.image.aibom: #{path} OK")
      found -> fail!(found)
    end
  end

  defp fail!(found) do
    Enum.each(found, &Mix.shell().error("FAIL AC7: #{&1}"))
    Mix.raise("trinity.image.aibom: #{length(found)} violation(s)")
  end

  @doc "Reads the models file: the `models` list, each entry a map with string keys."
  @spec read_models!(Path.t()) :: [map()]
  def read_models!(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{"models" => models}} when is_list(models) -> models
      {:ok, _} -> Mix.raise("#{path} has no `models` list")
      {:error, reason} -> Mix.raise("#{path} is not readable YAML: #{inspect(reason)}")
    end
  end

  @doc """
  The entries marked `shipped` whose legal review has not passed. The owner's rule (slice 133,
  D7) is that no weights are baked into an image before that review, so for the image's own
  models file this list must be empty; the test that runs it over `ci/headless/ai_models.yaml`
  is what holds the rule. A fixture may carry such an entry, which is why writing does not refuse it.
  """
  @spec unreviewed_shipped([map()]) :: [String.t()]
  def unreviewed_shipped(models) do
    for %{"delivery" => "shipped"} = m <- models,
        get_in(m, ["legal_review", "status"]) != "passed",
        do: to_string(get_in(m, ["space", "model_id"]))
  end

  @doc "The identity fields of an embedding space, as slice 133 defines them."
  @spec space_fields() :: [String.t()]
  def space_fields, do: @space_fields

  @doc """
  The space ID of a manifest: lowercase hex SHA-256 of its RFC 8785 canonical JSON, the same
  computation as slice 133's `Trinity.Memory.Space.id/1`.
  """
  @spec space_id(map()) :: String.t()
  def space_id(manifest) when is_map(manifest) do
    manifest |> Jcs.encode() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  @doc """
  The CycloneDX ML-BOM for a list of model entries. Options: `:image` and `:digest` name the
  image the bill describes, `:source` the file the entries came from.
  """
  @spec bom([map()], keyword()) :: map()
  def bom(models, opts \\ []) when is_list(models) do
    {model_components, data_components} =
      models |> Enum.map(&model_components/1) |> Enum.unzip()

    components = model_components ++ (data_components |> List.flatten() |> Enum.uniq())

    body = %{
      "bomFormat" => "CycloneDX",
      "specVersion" => @spec_version,
      "version" => 1,
      "metadata" => metadata(opts, length(models)),
      "components" => components
    }

    Map.put(body, "serialNumber", serial(body))
  end

  defp metadata(opts, count) do
    image =
      %{
        "type" => "container",
        "bom-ref" => "image",
        "name" => opts[:image] || "trinity-headless"
      }
      |> put_digest(opts[:digest])

    %{
      "component" => image,
      "properties" => [
        %{"name" => "trinity:bom-kind", "value" => "ai-bom"},
        %{"name" => "trinity:models-source", "value" => opts[:source] || @models},
        %{"name" => "trinity:model-count", "value" => Integer.to_string(count)},
        %{
          "name" => "trinity:coverage",
          "value" =>
            "The models this image carries (delivery shipped) and the models it is built to " <>
              "use only when an operator pulls them (delivery operator-accepted, never shipped). " <>
              "A model an operator connects or imports that is not listed here is the " <>
              "deployment's record, kept in its embedding space, not this bill's."
        }
      ]
    }
  end

  defp put_digest(component, nil), do: component

  defp put_digest(component, "sha256:" <> hex) do
    Map.put(component, "hashes", [%{"alg" => "SHA-256", "content" => hex}])
  end

  defp put_digest(_component, other), do: Mix.raise("--digest must be sha256:HEX, got #{other}")

  # A serial number derived from the content, so the same models give the same bill.
  defp serial(body) do
    <<a::binary-8, b::binary-4, _::binary-1, c::binary-3, _::binary-1, d::binary-3, e::binary-12,
      _::binary>> =
      body |> Jcs.encode() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    "urn:uuid:#{a}-#{b}-8#{c}-a#{d}-#{e}"
  end

  defp model_components(entry) do
    space = Map.get(entry, "space", %{})
    id = space_id(space)
    model_id = to_string(space["model_id"])
    {group, name} = split_model_id(model_id)
    review = get_in(entry, ["legal_review", "status"])
    delivery = entry["delivery"]
    datasets = entry["datasets"]

    data =
      if is_list(datasets), do: Enum.map(datasets, &data_component(model_id, &1)), else: []

    model =
      %{
        "type" => "machine-learning-model",
        "bom-ref" => "model:" <> id,
        "name" => name,
        "version" => to_string(space["revision"]),
        "scope" => if(delivery == "operator-accepted", do: "optional", else: "required"),
        "licenses" => licences(entry["licence"]),
        "properties" =>
          [
            %{"name" => "trinity:delivery", "value" => to_string(delivery)},
            %{"name" => "trinity:legal-review", "value" => to_string(review)},
            %{"name" => "trinity:space:id", "value" => id},
            %{"name" => "trinity:space:manifest", "value" => Jcs.encode(space)}
          ] ++ weights_properties(entry["weights"]),
        "modelCard" => model_card(entry, data)
      }
      |> put_if("group", group)
      |> put_if("description", entry["description"])
      |> put_if("hashes", weights_hashes(entry["weights"]))
      |> put_if("externalReferences", references(entry["source"]))

    {model, data}
  end

  defp split_model_id(model_id) do
    case String.split(model_id, "/", parts: 2) do
      [group, name] -> {group, name}
      [name] -> {nil, name}
    end
  end

  defp model_card(entry, data) do
    parameters =
      %{}
      |> put_if("task", entry["task"])
      |> put_if("architectureFamily", entry["architecture"])
      |> put_if(
        "datasets",
        if(is_list(entry["datasets"]), do: Enum.map(data, &%{"ref" => &1["bom-ref"]}))
      )

    review = entry["legal_review"] || %{}

    status =
      "Legal review of the licence and the training-data terms: " <>
        to_string(review["status"]) <>
        if(review["record"], do: " (#{review["record"]})", else: "")

    considerations =
      case entry["risks"] do
        risks when is_list(risks) and risks != [] ->
          Enum.map(risks, &%{"name" => to_string(&1), "mitigationStrategy" => status})

        _ ->
          []
      end

    %{
      "modelParameters" => parameters,
      "considerations" => %{"ethicalConsiderations" => considerations}
    }
  end

  defp data_component(model_id, %{"name" => name} = dataset) do
    %{
      "type" => "data",
      "bom-ref" => "dataset:" <> slug(model_id) <> ":" <> slug(name),
      "name" => name,
      "data" => [
        %{"type" => "dataset", "name" => name}
        |> put_if("description", dataset["description"])
      ],
      "licenses" => licences(dataset["licence"]),
      "properties" => [%{"name" => "trinity:training-data-of", "value" => model_id}]
    }
    |> put_if("externalReferences", references(dataset["source"]))
  end

  defp data_component(model_id, other) do
    %{
      "type" => "data",
      "bom-ref" => "dataset:invalid:" <> slug(inspect(other)),
      "name" => inspect(other),
      "data" => [],
      "licenses" => [],
      "properties" => [%{"name" => "trinity:training-data-of", "value" => model_id}]
    }
  end

  defp slug(text), do: text |> String.downcase() |> String.replace(~r/[^a-z0-9._-]+/, "-")

  # A licence is an SPDX id, a name with the terms quoted, or the word `unrecorded`.
  defp licences(@unrecorded), do: [%{"license" => %{"name" => @unrecorded}}]
  defp licences(%{"id" => id}), do: [%{"license" => %{"id" => id}}]

  defp licences(%{"name" => name} = licence) do
    text =
      case licence["text"] do
        nil -> nil
        content -> %{"contentType" => "text/plain", "content" => String.trim(content)}
      end

    [
      %{
        "license" => %{"name" => name} |> put_if("text", text) |> put_if("url", licence["url"])
      }
    ]
  end

  defp licences(_), do: []

  defp weights_hashes(%{"sha256" => hex}), do: [%{"alg" => "SHA-256", "content" => hex}]
  defp weights_hashes(_), do: nil

  defp weights_properties(%{"file" => file}),
    do: [%{"name" => "trinity:weights:file", "value" => file}]

  defp weights_properties(_), do: []

  defp references(nil), do: nil
  defp references(url), do: [%{"type" => "distribution", "url" => url}]

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc """
  Checks a bill against the profile above. Returns the violations, each a sentence; `[]` is a
  bill that passes.
  """
  @spec check(map()) :: [String.t()]
  def check(bom) when is_map(bom) do
    components = List.wrap(bom["components"])
    by_ref = Map.new(components, &{&1["bom-ref"], &1})

    document(bom) ++
      duplicate_refs(components) ++
      Enum.flat_map(
        Enum.filter(components, &(&1["type"] == "machine-learning-model")),
        &check_model(&1, by_ref)
      )
  end

  defp document(bom) do
    [
      {bom["bomFormat"] == "CycloneDX", "bomFormat is not CycloneDX"},
      {bom["specVersion"] == @spec_version, "specVersion is not #{@spec_version}"},
      {is_binary(bom["serialNumber"]) and Regex.match?(@serial, bom["serialNumber"]),
       "serialNumber is not a urn:uuid"},
      {is_integer(bom["version"]) and bom["version"] >= 1, "version is not a positive integer"},
      {is_map(get_in(bom, ["metadata", "component"])),
       "metadata.component does not name what the bill describes"},
      {is_list(bom["components"]), "components is not a list"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp duplicate_refs(components) do
    components
    |> Enum.map(& &1["bom-ref"])
    |> Enum.frequencies()
    |> Enum.filter(fn {_, n} -> n > 1 end)
    |> Enum.map(fn {ref, _} -> "bom-ref #{ref} is used by more than one component" end)
  end

  defp check_model(model, by_ref) do
    label = "model #{model["group"] && model["group"] <> "/"}#{model["name"]}"
    props = Map.new(List.wrap(model["properties"]), &{&1["name"], &1["value"]})
    delivery = props["trinity:delivery"]
    review = props["trinity:legal-review"]
    card = model["modelCard"] || %{}
    datasets = get_in(card, ["modelParameters", "datasets"])

    {manifest, space_problems} = space_violations(label, props)

    Enum.concat([
      space_problems,
      delivery_violations(label, delivery, model["scope"]),
      hash_violations(label, model["hashes"], delivery, manifest["weights_digest"]),
      licence_violations(label, model["licenses"]),
      dataset_violations(label, datasets, by_ref, review),
      consideration_violations(label, get_in(card, ["considerations", "ethicalConsiderations"])),
      review_violations(label, review)
    ])
  end

  defp delivery_violations(label, delivery, scope) do
    cond do
      delivery not in @deliveries ->
        ["#{label}: delivery #{inspect(delivery)} is not one of #{Enum.join(@deliveries, ", ")}"]

      delivery == "operator-accepted" and scope != "optional" ->
        ["#{label}: an operator-accepted model is never shipped, so its scope must be optional"]

      delivery == "shipped" and scope != "required" ->
        ["#{label}: a shipped model is in the image, so its scope must be required"]

      true ->
        []
    end
  end

  # The space manifest travels as its canonical JSON, so a reader can recompute the ID from the
  # property alone: SHA-256 of exactly those bytes.
  defp space_violations(label, props) do
    with text when is_binary(text) <- props["trinity:space:manifest"],
         {:ok, manifest} when is_map(manifest) <- Jason.decode(text) do
      keys = manifest |> Map.keys() |> Enum.sort()
      id = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

      problems =
        [
          {keys == Enum.sort(@space_fields),
           "#{label}: the space manifest's fields are #{inspect(keys)}, not slice 133's fourteen"},
          {Jcs.encode(manifest) == text,
           "#{label}: the space manifest is not in RFC 8785 canonical form"},
          {props["trinity:space:id"] == id,
           "#{label}: trinity:space:id is not the SHA-256 of the space manifest (#{id})"}
        ]
        |> Enum.reject(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      {manifest, problems}
    else
      _ -> {%{}, ["#{label}: no embedding space manifest (trinity:space:manifest)"]}
    end
  end

  defp hash_violations(label, hashes, delivery, digest) do
    sha256 =
      Enum.find_value(List.wrap(hashes), fn
        %{"alg" => "SHA-256", "content" => hex} when is_binary(hex) -> hex
        _ -> nil
      end)

    cond do
      delivery == "shipped" and is_nil(sha256) ->
        ["#{label}: no SHA-256 of the weights the image carries"]

      is_nil(sha256) ->
        []

      not Regex.match?(@sha256, sha256) ->
        ["#{label}: the SHA-256 #{inspect(sha256)} is not 64 lowercase hex characters"]

      sha256 != digest ->
        ["#{label}: the weights hash #{sha256} is not the space's weights_digest #{digest}"]

      true ->
        []
    end
  end

  defp licence_violations(label, licences) do
    if Enum.any?(List.wrap(licences), &licence_named?/1),
      do: [],
      else: ["#{label}: no licence"]
  end

  defp licence_named?(%{"license" => %{"id" => id}}) when is_binary(id) and id != "", do: true

  defp licence_named?(%{"license" => %{"name" => name}}) when is_binary(name) and name != "",
    do: true

  defp licence_named?(_), do: false

  defp dataset_violations(label, datasets, by_ref, review) do
    case datasets do
      [_ | _] -> Enum.flat_map(datasets, &dataset_ref_violations(label, &1, by_ref, review))
      _ -> ["#{label}: no training dataset is listed (modelCard.modelParameters.datasets)"]
    end
  end

  defp dataset_ref_violations(label, %{"ref" => ref}, by_ref, review) do
    case by_ref[ref] do
      %{"type" => "data"} = data -> data_licence_violations(label, data, review)
      _ -> ["#{label}: dataset reference #{ref} resolves to no data component"]
    end
  end

  defp dataset_ref_violations(label, other, _by_ref, _review),
    do: ["#{label}: dataset entry #{inspect(other)} is not a reference to a data component"]

  defp data_licence_violations(label, data, review) do
    licences = List.wrap(data["licenses"])
    name = data["name"]

    cond do
      Enum.any?(licences, &match?(%{"license" => %{"name" => @unrecorded}}, &1)) ->
        if review == "passed",
          do: ["#{label}: dataset #{name}'s licence is unrecorded, but the legal review passed"],
          else: []

      Enum.any?(licences, &data_licence_stated?/1) ->
        []

      true ->
        ["#{label}: dataset #{name} has no licence: an SPDX id, or a name with the terms quoted"]
    end
  end

  defp data_licence_stated?(%{"license" => %{"id" => id}}) when is_binary(id) and id != "",
    do: true

  defp data_licence_stated?(%{"license" => %{"name" => _, "text" => %{"content" => text}}})
       when is_binary(text) and text != "",
       do: true

  defp data_licence_stated?(_), do: false

  defp consideration_violations(label, considerations) do
    named =
      Enum.filter(List.wrap(considerations), fn c ->
        is_binary(c["name"]) and c["name"] != "" and is_binary(c["mitigationStrategy"])
      end)

    if named == [],
      do: ["#{label}: no consideration names a risk (modelCard.considerations)"],
      else: []
  end

  defp review_violations(_label, review) when review in @reviews, do: []

  defp review_violations(label, review),
    do: [
      "#{label}: legal review status #{inspect(review)} is not one of #{Enum.join(@reviews, ", ")}"
    ]
end
