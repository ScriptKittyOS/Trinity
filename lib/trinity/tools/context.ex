# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Context do
  @moduledoc """
  What a tool call knows about where it runs. Slice 020. `caller` names the process that asked
  (the Session's id at this slice; a subagent's or a gateway's later); `cwd` is the working
  directory 022's filesystem and shell tools resolve paths against; `persona` is the row.
  `call_id` (slice 024) is the model's id for this call, set by the runner per call; with
  the session it is the effect's idempotency key. `tool` (slice 060) is the registry name the
  call was made under, set beside `call_id`, so a module serving many dynamic tools (the MCP
  bridge) knows which one it is.
  """

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          cwd: String.t() | nil,
          persona: struct() | map() | nil,
          caller: term(),
          call_id: String.t() | nil,
          tool: String.t() | nil,
          origin: String.t() | nil,
          trace: map() | nil,
          principal: map() | nil
        }

  defstruct session_id: nil,
            cwd: nil,
            persona: nil,
            caller: nil,
            call_id: nil,
            tool: nil,
            origin: nil,
            trace: nil,
            principal: nil
end
