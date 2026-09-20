# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Shell.Run do
  @moduledoc """
  `shell`: a command under `/bin/sh -c` through MuonTrap. Slice 022, POSIX only.

  What holds: the child is a MuonTrap port, sent SIGTERM at the timeout and SIGKILL 500 ms
  later, and it dies with the port when the runner's task dies (the guarantee docs/02 chose
  MuonTrap for); the working directory is the session's, inside the roots, or `:ask`; the
  environment is scrubbed to `PATH`, `HOME`, `LANG`, `LC_ALL`, `TERM`, `TMPDIR` and `USER`, so
  no key in Trinity's environment reaches the child; the timeout is 120 s by default and at
  most 600 s; the output is capped at 1 MB, the head and the tail kept; the risk is `:exec`,
  and a command matching `Trinity.Tools.Shell.Dangerous` is `:destructive`.

  On Windows `available?/0` is false and the registry does not register this tool: no
  runtime in the tree keeps the guarantee there, and a fallback that could orphan a process
  would be a different tool under the same name (NOTES.md, the Windows decision).
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, FS, Untrusted}
  alias Trinity.Tools.Shell.Dangerous

  @default_timeout_ms 120_000
  @max_timeout_ms 600_000
  @output_cap 1_048_576
  @env_keep ~w(PATH HOME LANG LC_ALL TERM TMPDIR USER)

  @impl true
  def name, do: "shell"
  @impl true
  def description,
    do:
      "Runs a shell command (/bin/sh -c) in the working directory and returns its output and exit status. Timeout 120 s by default (`timeout_ms`, at most 600 s). Output is capped at 1 MB. Commands that could destroy data ask for approval."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "minLength" => 1},
        "cwd" => %{
          "type" => "string",
          "description" => "A directory under the working directory or the roots"
        },
        "timeout_ms" => %{"type" => "integer", "minimum" => 100, "maximum" => @max_timeout_ms}
      },
      "required" => ["command"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :exec
  @impl true
  def effect, do: :catalog
  @impl true
  def timeout, do: @max_timeout_ms + 5_000

  @impl true
  def available?, do: match?({:unix, _}, :os.type()) and Code.ensure_loaded?(MuonTrap)

  @impl true
  def escalate(%{"command" => command} = args, %Context{cwd: cwd}) do
    cond do
      Dangerous.match(command) != [] -> :destructive
      match?({:ok, _, :outside}, FS.resolve(Map.get(args, "cwd", "."), cwd)) -> :ask
      true -> nil
    end
  end

  @impl true
  def execute(%{"command" => command} = args, %Context{cwd: cwd}) do
    {:ok, dir, _} = FS.resolve(Map.get(args, "cwd", "."), cwd)
    timeout = args |> Map.get("timeout_ms", @default_timeout_ms) |> min(@max_timeout_ms)

    if File.dir?(dir) do
      run(command, dir, timeout)
    else
      {:error, {:cwd, "no such directory: #{dir}"}}
    end
  end

  defp run(command, dir, timeout) do
    started = System.monotonic_time(:millisecond)

    {output, status} =
      MuonTrap.cmd("/bin/sh", ["-c", command],
        cd: dir,
        env: scrubbed_env(),
        stderr_to_stdout: true,
        timeout: timeout,
        delay_to_sigkill: 500
      )

    elapsed = System.monotonic_time(:millisecond) - started
    {text, capped?} = cap(output)

    meta = %{
      "command" => command,
      "cwd" => dir,
      "exit_status" => if(status == :timeout, do: nil, else: status),
      "timed_out" => status == :timeout,
      "elapsed_ms" => elapsed,
      "output_bytes" => byte_size(output),
      "capped" => capped?
    }

    trailer =
      case status do
        :timeout -> "\n[killed: the command did not finish within #{timeout} ms]"
        0 -> ""
        n -> "\n[exit status #{n}]"
      end

    {:ok, Untrusted.result(text <> trailer, tool: "shell", source_ref: command, meta: meta)}
  end

  @doc """
  The environment the child sees: the kept names with their values, and every other name
  Trinity's own environment carries unset (`nil`), since a port's `env:` adds to the inherited
  environment rather than replacing it (measured at slice 022: the first version kept only
  the seven names and the child still saw every key).
  """
  @spec scrubbed_env() :: [{String.t(), String.t() | nil}]
  def scrubbed_env do
    keep =
      for name <- @env_keep, value = System.get_env(name), is_binary(value), do: {name, value}

    unset = for {name, _} <- System.get_env(), name not in @env_keep, do: {name, nil}
    keep ++ unset
  end

  # Over the cap: the first half and the last half of what fits, with the gap named.
  defp cap(output) when byte_size(output) > @output_cap do
    half = div(@output_cap, 2)
    head = binary_part(output, 0, half) |> String.chunk(:valid) |> Enum.join()

    tail =
      binary_part(output, byte_size(output) - half, half) |> String.chunk(:valid) |> Enum.join()

    {head <> "\n[... #{byte_size(output) - @output_cap} bytes omitted ...]\n" <> tail, true}
  end

  defp cap(output), do: {output, false}
end
