# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule VersionFormTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Trinity.VersionForm

  @moduledoc """
  There is no exemption list. The pattern is case-sensitive on word boundaries, which is what
  excludes lower-case library version strings, not a list of allowed sites.
  """

  test "the skip list holds exactly one entry: the enforcer's own source" do
    assert VersionForm.skip_list() == ["lib/mix/tasks/trinity.version_form.ex"],
           "the skip list must not grow. It exists only because this module has to contain the " <>
             "pattern in order to test it. Got: #{inspect(VersionForm.skip_list())}"
  end

  # The forbidden strings are COMPOSED at runtime, never written literally. Writing them here
  # would make this file a violation, and the skip list is not allowed to grow to cover it:
  # it holds exactly one entry, the enforcer's own source, and another test asserts that.
  @protocol "MCP"

  test "the forbidden form is caught" do
    assert VersionForm.forbidden?("we target " <> @protocol <> " " <> "2.0" <> " now")
    assert VersionForm.forbidden?(@protocol <> " " <> "3.1" <> " is not a thing either")
  end

  test "lower-case library version strings are excluded by the word boundary, not by a list" do
    refute VersionForm.forbidden?("gen_mcp 2.0 is server-only")
    refute VersionForm.forbidden?("| anubis_mcp 2.0.x | LGPL-3.0 |")
    refute VersionForm.forbidden?("depends on gen_mcp 2.0.0")
  end

  test "the date-versioned form is fine" do
    refute VersionForm.forbidden?(@protocol <> " 2026-07-28 is the target")
  end
end
