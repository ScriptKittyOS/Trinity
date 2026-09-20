# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Context do
  @moduledoc """
  What a tool call knows about where it runs. Slice 020. `caller` names the process that asked
  (the Session's id at this slice; a subagent's or a gateway's later); `cwd` is the working
  directory 022's filesystem and shell tools resolve paths against; `persona` is the row.
  `call_id` (slice 024) is the model's id for this call, set by the runner per call; with
  the session it is the effect's idempotency key.
  """

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          cwd: String.t() | nil,
          persona: struct() | map() | nil,
          caller: term(),
          call_id: String.t() | nil
        }

  defstruct session_id: nil, cwd: nil, persona: nil, caller: nil, call_id: nil
end
