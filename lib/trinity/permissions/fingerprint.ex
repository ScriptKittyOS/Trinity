# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Fingerprint do
  @moduledoc """
  The fingerprint an approval binds (docs/07, M2): SHA-256, hex, over the RFC 8785 canonical
  form of `{tool, args, scope, cwd, canonicalization_version}`. Re-derived from the arguments
  actually passed at execution; a divergence denies. Slice 021.

  `canonicalization_version` is 1 and is part of the digest, so a change of scheme is a new
  version and never a silent difference in old fingerprints.
  """

  @version 1

  @doc "The canonicalization version bound into every fingerprint."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "RFC 8785 canonical JSON of a term (maps with string keys, lists, strings, numbers, booleans, nil)."
  @spec canonical(term()) :: String.t()
  def canonical(term), do: Jcs.encode(term)

  @doc "The fingerprint of a call in a scope and working directory."
  @spec of(String.t(), map(), String.t(), String.t() | nil) :: String.t()
  def of(tool, args, scope, cwd) when is_binary(tool) and is_map(args) and is_binary(scope) do
    payload = %{
      "tool" => tool,
      "args" => args,
      "scope" => scope,
      "cwd" => cwd,
      "canonicalization_version" => @version
    }

    :crypto.hash(:sha256, canonical(payload)) |> Base.encode16(case: :lower)
  end
end
