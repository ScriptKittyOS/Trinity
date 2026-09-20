# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Content.Part do
  @moduledoc """
  One piece of content with its provenance (docs/07, M1). Slice 022.

  `origin` names where the bytes came from (`"tool:web_fetch"`, `"tool:shell"`, `"tool:fs_read"`,
  `"model"`, `"user"`); `source_ref` the address (a URL, a path, a command); `digest` the SHA-256
  of the text; `taint` whether the prompt may treat it as an instruction: `:trusted` (the user,
  the persona, configuration), `:untrusted` (anything that came from outside the app: a page, a
  file, a command's output, a model's answer that read one), `:blocked` (a part the prompt
  builder replaces by a placeholder). A summary or a compaction carries the maximum taint of
  its inputs (`max_taint/1`).

  Stored on rows as string-keyed maps (`to_map/1`, `from_map/1`).
  """

  @type taint :: :trusted | :untrusted | :blocked
  @type t :: %__MODULE__{
          origin: String.t(),
          source_ref: String.t() | nil,
          digest: String.t(),
          taint: taint(),
          text: String.t()
        }

  defstruct origin: "model", source_ref: nil, digest: "", taint: :trusted, text: ""

  @order %{trusted: 0, untrusted: 1, blocked: 2}

  @doc "A part over `text`, digest computed."
  @spec new(String.t(), keyword()) :: t()
  def new(text, opts \\ []) when is_binary(text) do
    %__MODULE__{
      origin: Keyword.get(opts, :origin, "model"),
      source_ref: Keyword.get(opts, :source_ref),
      digest: digest(text),
      taint: Keyword.get(opts, :taint, :trusted),
      text: text
    }
  end

  @doc "SHA-256, hex."
  @spec digest(String.t()) :: String.t()
  def digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @doc "The highest taint among parts or taints; `:trusted` for none."
  @spec max_taint([t() | taint()]) :: taint()
  def max_taint(items) do
    items
    |> Enum.map(fn
      %__MODULE__{taint: t} -> t
      t when is_atom(t) -> t
    end)
    |> Enum.max_by(&Map.fetch!(@order, &1), fn -> :trusted end)
  end

  @doc "True when `a` is at least as tainted as `b`."
  @spec at_least?(taint(), taint()) :: boolean()
  def at_least?(a, b), do: Map.fetch!(@order, a) >= Map.fetch!(@order, b)

  @doc "The string-keyed map a row stores."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = p) do
    %{
      "origin" => p.origin,
      "source_ref" => p.source_ref,
      "digest" => p.digest,
      "taint" => Atom.to_string(p.taint),
      "text" => p.text
    }
  end

  @doc "A part from a stored map; an unknown taint reads as `:untrusted`, the safe direction."
  @spec from_map(map()) :: t()
  def from_map(%{} = m) do
    %__MODULE__{
      origin: m["origin"] || "unknown",
      source_ref: m["source_ref"],
      digest: m["digest"] || "",
      taint: taint_from(m["taint"]),
      text: m["text"] || ""
    }
  end

  defp taint_from("trusted"), do: :trusted
  defp taint_from("blocked"), do: :blocked
  defp taint_from(_), do: :untrusted
end
