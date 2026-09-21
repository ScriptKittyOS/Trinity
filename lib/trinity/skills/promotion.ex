# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Promotion do
  @moduledoc """
  The one path that moves a staged change into a skill root (slice 041, AC8: the census over
  the tree finds exactly one caller of `swap/3`, `Trinity.Skills.Manager`). `swap/3` takes
  the change, an approval id and the deciding party, and refuses by name unless the approval
  row exists, was allowed, was for `skill_apply`, and names this change's id and digest in
  its arguments (the fingerprint 021 bound); then it recomputes the pending tree's digest
  against the row's, archives the skill as it is under `<root>/.history/<name>/v<version>/`,
  renames the pending tree into place (atomic per directory), rescans the registry, writes an
  `effect` receipt on the `skills` chain scope carrying the change's digest and the approval
  id, and marks the row `applied` with the version now in the registry. A step that fails
  after the rename leaves the row `failed` with the reason; the files are in place and the
  receipt says what happened, or the alarm does.
  """

  alias Trinity.Permissions.Approval
  alias Trinity.Repo
  alias Trinity.Skills.{Change, Registry, Sources, Staging}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @tool "skill_apply"
  @scope "skills"

  @doc "The tool name the approval carries."
  @spec tool() :: String.t()
  def tool, do: @tool

  @doc "The receipt chain scope promotions write on."
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc "Promotes a pending change under an approval; every refusal is named. `comment` is the decider's, kept on the row."
  @spec swap(Change.t(), String.t() | nil, String.t(), String.t() | nil) ::
          {:ok, Change.t()} | {:error, term()}
  def swap(change, approval_id, by, comment \\ nil)

  def swap(%Change{} = change, approval_id, by, comment)
      when is_binary(approval_id) and is_binary(by) do
    with {:ok, approval} <- approval(change, approval_id),
         :ok <- pending?(change),
         :ok <- digest_holds?(change) do
      promote(change, approval, by, comment)
    end
  end

  def swap(%Change{}, nil, _by, _comment), do: {:error, :approval_required}

  defp approval(change, id) do
    case Trinity.Permissions.get_approval(id) do
      nil ->
        {:error, {:no_such_approval, id}}

      %Approval{tool: @tool, status: "allowed", args: args} = a ->
        if args["change_id"] == change.id and args["digest"] == change.digest,
          do: {:ok, a},
          else: {:error, {:approval_for_another_change, id}}

      %Approval{tool: @tool, status: status} ->
        {:error, {:approval_not_allowed, status}}

      %Approval{tool: other} ->
        {:error, {:approval_for_another_tool, other}}
    end
  end

  defp pending?(%Change{status: "pending"}), do: :ok
  defp pending?(%Change{status: s}), do: {:error, {:not_pending, s}}

  defp digest_holds?(%Change{change_dir: dir, digest: digest}) do
    cond do
      not File.dir?(dir) -> {:error, :staged_files_missing}
      Staging.digest(dir) != digest -> {:error, :staged_files_changed}
      true -> :ok
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the paths are the target root joined with the
  # change's skill name (validated at staging) and the change's own pending directory.
  @sobelow_skip ["Traversal.FileModule"]
  defp promote(%Change{} = change, %Approval{} = approval, by, comment) do
    root = Path.expand(Sources.user_dir())
    target = Path.join(root, change.skill_name)
    File.mkdir_p!(root)
    previous = Registry.get(change.skill_name)
    version_before = if previous && previous.source == "user", do: previous.version, else: 0
    archive!(target, root, change.skill_name, version_before)

    if change.action == "delete" do
      File.rm_rf!(change.change_dir)
    else
      File.rename!(change.change_dir, target)
    end

    Registry.rescan()
    now = Registry.get(change.skill_name)

    version =
      if change.action == "delete", do: nil, else: now && now.source == "user" && now.version

    receipt =
      Trinity.Receipts.append(@scope, %{
        kind: "effect",
        subject: %{
          "skill" => change.skill_name,
          "action" => change.action,
          "change_id" => change.id,
          "digest" => change.digest,
          "approval_id" => approval.id,
          "decided_by" => by,
          "version" => version
        },
        subject_ref: "skill:#{change.skill_name}@#{change.digest}",
        meta: %{"phase" => "done", "destructive" => change.destructive}
      })

    case receipt do
      {:ok, r} ->
        change
        |> Change.changeset(%{
          status: "applied",
          approval_id: approval.id,
          decided_by: by,
          decided_at: DateTime.utc_now(),
          receipt_hash: r.receipt_hash,
          applied_version: version,
          comment: comment
        })
        |> Repo.update()

      {:error, reason} ->
        {:ok, _} =
          change
          |> Change.changeset(%{
            status: "failed",
            approval_id: approval.id,
            decided_by: by,
            comment: "receipt: #{inspect(reason)}"
          })
          |> Repo.update()

        {:error, {:promoted_but_not_receipted, reason}}
    end
  end

  # The skill as it is, if it exists, to `.history/<name>/v<n>/`.
  # sobelow_skip reason: Traversal.FileModule: `target` and the history path are the root
  # joined with the validated name and a version number.
  @sobelow_skip ["Traversal.FileModule"]
  defp archive!(target, root, name, version) do
    if File.dir?(target) do
      history = Path.join([root, ".history", name, "v#{version}"])
      File.rm_rf!(history)
      File.mkdir_p!(Path.dirname(history))
      File.rename!(target, history)
    end

    :ok
  end
end
