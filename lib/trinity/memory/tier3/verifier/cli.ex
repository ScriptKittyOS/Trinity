# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Tier3.Verifier.CLI do
  @moduledoc """
  The verifier as the reference programs (slice 134), from paths in the options (`cosign:`,
  `model_signing:`) or found on `PATH`:

      cosign verify --key <key> --offline=true --local-image --insecure-ignore-tlog=true <layout>
      model_signing verify key --signature <sig> --public_key <key> <model dir>

  `--insecure-ignore-tlog=true` because an air-gapped import host has no transparency log to
  consult: the operator's key is the trust (D6; the Sigstore Cosign 2.0 notes say a signature
  made with `--tlog-upload=false` is verified this way). Exit status 0 is a pass; anything else,
  or a program that cannot be found, is a refusal carrying the program's last lines.
  """
  @behaviour Trinity.Memory.Tier3.Verifier

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @impl true
  def cosign(layout, public_key, opts) do
    args = [
      "verify",
      "--key",
      public_key,
      "--offline=true",
      "--local-image",
      "--insecure-ignore-tlog=true",
      layout
    ]

    with {:ok, program} <- program(opts, :cosign, "cosign") do
      run(program, args, :cosign_refused)
    end
  end

  @impl true
  def oms(model_dir, signature, public_key, opts) do
    args = ["verify", "key", "--signature", signature, "--public_key", public_key, model_dir]

    with {:ok, program} <- program(opts, :model_signing, "model_signing") do
      run(program, args, :oms_refused)
    end
  end

  defp program(opts, key, name) do
    case Keyword.get(opts, key) || System.find_executable(name) do
      nil -> {:error, {:program_missing, name}}
      path -> if File.regular?(path), do: {:ok, path}, else: {:error, {:program_missing, path}}
    end
  end

  # sobelow_skip reason: CI.System: the program is the operator's own cosign or model_signing
  # (an option of the import task, or found on PATH), run with a fixed argument list whose only
  # variables are paths the import created or the operator named; nothing comes from a model or a
  # network peer.
  @sobelow_skip ["CI.System"]
  defp run(program, args, refusal) do
    case System.cmd(program, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {refusal, status, tail(out)}}
    end
  rescue
    e in ErlangError -> {:error, {refusal, :not_run, Exception.message(e)}}
  end

  defp tail(out), do: out |> String.split("\n", trim: true) |> Enum.take(-3) |> Enum.join("\n")
end
