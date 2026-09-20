# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Authority.Staged do
  @moduledoc """
  An effect about to happen, as the membrane hands it to the authority (slice 024): the tool
  (name, module, effect class), the validated arguments, the call id (the idempotency key
  with the session), the session and scope, the working directory, the gate's decision and
  the fingerprint that decision bound.
  """

  @type t :: %__MODULE__{
          tool: String.t(),
          module: module(),
          effect: :artifact | :catalog,
          args: map(),
          call_id: String.t() | nil,
          session_id: String.t() | nil,
          scope: String.t(),
          cwd: String.t() | nil,
          decision: :allow | :deny | :ask,
          basis: map(),
          fingerprint: String.t() | nil,
          staged_at: DateTime.t() | nil
        }

  @enforce_keys [:tool, :module, :effect, :args, :scope, :decision, :fingerprint]
  defstruct tool: nil,
            module: nil,
            effect: nil,
            args: %{},
            call_id: nil,
            session_id: nil,
            scope: nil,
            cwd: nil,
            decision: nil,
            basis: %{},
            fingerprint: nil,
            staged_at: nil

  @doc "The subject reference an effect receipt carries: `effect:<session>:<call id>`."
  @spec subject_ref(t()) :: String.t()
  def subject_ref(%__MODULE__{session_id: s, call_id: c}),
    do: "effect:#{s || "none"}:#{c || "none"}"
end
