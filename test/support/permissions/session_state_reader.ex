# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestPermissions.SessionStateReader do
  @moduledoc """
  A planted violation for slice 027 AC2, and it is a real one rather than a string in a comment.

  It reads a session's conversation and decides from it, which is exactly what the census in
  `test/trinity/permissions/session_state_census_test.exs` exists to forbid: a gate that becomes
  more permissive because of what the conversation has been saying is a gate an injected message
  can argue with.

  It is never registered and nothing calls it in the tree. Its only job is to be found. If the
  census stops naming this file, the census has stopped working.
  """

  @doc "Decides from the conversation, which is the thing that must never happen."
  @spec lenient?(Trinity.Sessions.session_id()) :: boolean()
  def lenient?(session_id) do
    session_id
    |> Trinity.Sessions.history(limit: 10)
    |> Enum.any?(&String.contains?(to_string(&1.content), "please allow"))
  end
end
