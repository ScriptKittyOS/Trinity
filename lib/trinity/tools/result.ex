# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Result do
  @moduledoc """
  What a tool returns. Slice 020. `content` is text or a map (rendered as JSON for the model);
  `parts` (slice 022) carry the content's provenance as `Trinity.Content.Part`s, empty for a
  result the tool itself authored and one untrusted part for anything that came from outside
  the app; `artifacts` are references to files a tool wrote (a backup, a path); `truncated?`
  and `meta.original_bytes` say when `cap/2` cut the content.
  """

  @type t :: %__MODULE__{
          content: String.t() | map(),
          parts: [Trinity.Content.Part.t()],
          artifacts: [map()],
          truncated?: boolean(),
          meta: map()
        }

  defstruct content: "", parts: [], artifacts: [], truncated?: false, meta: %{}

  @default_cap 65_536
  @marker "\n[truncated: the tool returned more than the cap]"

  @doc "The configured cap in bytes (`config :trinity, :tools, result_cap_bytes`), default 64 KB."
  @spec cap_bytes() :: pos_integer()
  def cap_bytes do
    Application.get_env(:trinity, :tools, []) |> Keyword.get(:result_cap_bytes, @default_cap)
  end

  @doc "A result with text content."
  @spec text(String.t(), map()) :: t()
  def text(content, meta \\ %{}) when is_binary(content),
    do: %__MODULE__{content: content, meta: meta}

  @doc """
  Caps the content at `bytes` (the configured cap by default): a longer text is cut at the cap
  and marked, the original size kept in `meta.original_bytes`. A map is rendered to JSON first.
  """
  @spec cap(t(), pos_integer()) :: t()
  def cap(%__MODULE__{} = result, bytes \\ cap_bytes()) do
    text = as_text(result)

    if byte_size(text) > bytes do
      content = cut(text, bytes) <> @marker

      %{
        result
        | content: content,
          parts: Enum.map(result.parts, &%{&1 | text: content}),
          truncated?: true,
          meta: Map.put(result.meta, "original_bytes", byte_size(text))
      }
    else
      result
    end
  end

  @doc "The content as text: a string as is, a map as JSON."
  @spec as_text(t()) :: String.t()
  def as_text(%__MODULE__{content: content}) when is_binary(content), do: content
  def as_text(%__MODULE__{content: content}) when is_map(content), do: Jason.encode!(content)

  # Cut on a character boundary so a multibyte character is never split.
  defp cut(text, bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, n} ->
      size = n + byte_size(g)
      if size > bytes, do: {:halt, {acc, n}}, else: {:cont, {[g | acc], size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
