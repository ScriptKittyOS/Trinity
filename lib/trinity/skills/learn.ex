# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Learn do
  @moduledoc """
  A document into a knowledge skill (slice 041, `/learn`): the source (a file under the
  session's roots, a URL, or pasted text) is distilled by the model given into a lean
  SKILL.md (the frontmatter and a body under 200 lines) and one `references/` file (the
  detail the body points at), then staged as a `create` like any other change: nothing lands
  without an approval. The source's text is data; it is sent to the model the operator chose
  for the session and to nothing else.
  """

  alias Trinity.LLM
  alias Trinity.LLM.Request
  alias Trinity.Skills.Staging
  alias Trinity.Tools.{Context, FS}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @max_source_bytes 200_000
  @max_body_lines 200

  @schema %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "category" => %{"type" => "string"},
      "body" => %{"type" => "string"},
      "reference_name" => %{"type" => "string"},
      "reference" => %{"type" => "string"}
    },
    "required" => ["name", "description", "body", "reference"]
  }

  @doc "The JSON Schema the model answers with."
  @spec schema() :: map()
  def schema, do: @schema

  @doc """
  Reads the source: `%{"file" => path}` under the session's roots, `%{"url" => url}` through
  the web fetch tool, or `%{"text" => text}`; at most #{@max_source_bytes} bytes either way.
  """
  @spec read_source(map(), Context.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  # sobelow_skip reason: Traversal.FileModule: the path is resolved by `Trinity.Tools.FS`
  # against the session's working directory and read only when inside the configured roots.
  @sobelow_skip ["Traversal.FileModule"]
  def read_source(%{"file" => path}, %Context{cwd: cwd}) when is_binary(path) do
    case FS.resolve(path, cwd) do
      {:ok, real, :inside} ->
        with {:ok, bytes} <- File.read(real),
             do: {:ok, String.slice(bytes, 0, @max_source_bytes), "file:" <> real}

      {:ok, _real, :outside} ->
        {:error, {:outside_roots, path}}
    end
  end

  def read_source(%{"url" => url}, ctx) when is_binary(url) do
    case Trinity.Tools.Web.Fetch.execute(%{"url" => url}, ctx) do
      {:ok, %{content: text}} -> {:ok, String.slice(text, 0, @max_source_bytes), "url:" <> url}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_source(%{"text" => text}, _ctx) when is_binary(text),
    do: {:ok, String.slice(text, 0, @max_source_bytes), "text"}

  def read_source(_, _), do: {:error, {:args, "learn needs file, url or text"}}

  @doc "Asks the model for the skill; the answer cleaned to a name the parser accepts and a body under the line cap."
  @spec distil(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def distil(text, source_ref, opts \\ []) do
    request =
      Request.new!(%{
        model: Keyword.get(opts, :model),
        system:
          "You turn a document into a skill for a personal agent, in the agentskills.io shape. " <>
            "Answer with: name (lowercase words joined by hyphens, at most 64 characters, describing the task the skill covers); " <>
            "description (one or two sentences: what the skill does and when to use it, with the words a person would use); " <>
            "category (one lowercase word); body (Markdown: the procedure or the knowledge, step by step, under #{@max_body_lines} lines, " <>
            "pointing at the reference file for detail); reference_name (a file name like overview.md); " <>
            "reference (Markdown: the detail worth keeping from the document, condensed). Keep only what a future task needs. Invent nothing.",
        messages: [%{role: "user", content: "Source: #{source_ref}\n\n" <> text}]
      })

    case LLM.generate_object(request, @schema, session_id: Keyword.get(opts, :session_id)) do
      {:ok, %{"name" => _, "body" => _} = obj} -> {:ok, clean(obj)}
      {:ok, other} -> {:error, {:no_skill, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads, distils and stages; `opts`: `model:`, `session_id:`."
  @spec learn(map(), Context.t(), keyword()) ::
          {:ok, Trinity.Skills.Change.t()} | {:error, term()}
  def learn(source, %Context{} = ctx, opts \\ []) do
    with {:ok, text, ref} <- read_source(source, ctx),
         {:ok, skill} <- distil(text, ref, opts) do
      md =
        "---\nname: #{skill.name}\ndescription: #{yaml_string(skill.description)}\nmetadata:\n  category: #{skill.category}\n  learned_from: #{yaml_string(ref)}\n---\n\n" <>
          skill.body <> "\n"

      Staging.propose(
        "create",
        skill.name,
        %{
          "skill_md" => md,
          "files" => %{("references/" <> skill.reference_name) => skill.reference <> "\n"}
        },
        rationale: "learned from #{ref}",
        proposed_by: ctx.session_id
      )
    end
  end

  @doc "The page's entry: a source for a project root and persona, without a session (the change's `proposed_by` is nil)."
  @spec learn_for(map(), String.t() | nil, map() | nil) ::
          {:ok, Trinity.Skills.Change.t()} | {:error, term()}
  def learn_for(source, project_root, persona) do
    ctx = %Context{cwd: project_root, persona: persona}
    learn(source, ctx, model: persona && Map.get(persona, :model))
  end

  defp clean(obj) do
    name =
      obj["name"]
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 64)
      |> String.trim("-")

    body =
      obj["body"]
      |> to_string()
      |> String.split("\n")
      |> Enum.take(@max_body_lines)
      |> Enum.join("\n")

    ref_name =
      (obj["reference_name"] || "overview.md")
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9.\-]+/, "-")
      |> then(&if(String.ends_with?(&1, ".md"), do: &1, else: &1 <> ".md"))

    %{
      name: if(name == "", do: "learned-skill", else: name),
      description:
        obj["description"]
        |> to_string()
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 1_000),
      category:
        (obj["category"] || "knowledge")
        |> to_string()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "-"),
      body: body,
      reference_name: ref_name,
      reference: to_string(obj["reference"])
    }
  end

  # A double-quoted YAML scalar for a description that may hold a colon or a quote.
  defp yaml_string(s),
    do: "\"" <> String.replace(String.replace(s, "\\", "\\\\"), "\"", "\\\"") <> "\""
end
