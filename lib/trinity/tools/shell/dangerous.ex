# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Shell.Dangerous do
  @moduledoc """
  The pattern list docs/07 asks for (shell): a command matching one is `:destructive` and asks
  whatever the shell's default. A tripwire over text, stated as such: it catches the shapes
  named here and nothing cleverer; the gate, the cwd jail and the timeout are the controls.
  Slice 022.
  """

  @patterns [
    {"rm -rf on a root, home or wildcard",
     ~r/\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\w*\s+(\/|~|\*|\$HOME|\.\.)(\s|$|\/)/},
    {"rm -rf /", ~r/\brm\s+-rf\s+\/(\s|$)/},
    {"piping a download into a shell",
     ~r/\b(curl|wget)\b.*\|\s*(sudo\s+)?(sh|bash|zsh|python[0-9.]*|perl)\b/},
    {"sudo or su", ~r/(^|\s|;|&&|\|\|)\s*(sudo|su)\b/},
    {"chmod 777 or a recursive chmod on a root",
     ~r/\bchmod\s+(-R\s+)?(777|a\+rwx)\b|\bchmod\s+-R\s+\S+\s+\/(\s|$)/},
    {"chown on a root", ~r/\bchown\s+-R\s+\S+\s+\/(\s|$)/},
    {"mkfs or a disk write",
     ~r/\b(mkfs|fdisk|parted|wipefs)\b|\bdd\b.*\bof=\/dev\/|>\s*\/dev\/(sd|nvme|hd|disk)/},
    {"a fork bomb", ~r/:\(\)\s*\{\s*:\|:&\s*\};:|\bfork\s*bomb\b/},
    {"a forced git push or history rewrite",
     ~r/\bgit\s+push\b.*(--force|-f\b|\+[a-zA-Z])|\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*f)/},
    {"shutdown, reboot or halt", ~r/\b(shutdown|reboot|halt|poweroff|init\s+[06])\b/},
    {"killing everything", ~r/\b(kill\s+-9\s+-1|killall\s+-9|pkill\s+-9\s+\.)\b/},
    {"overwriting the shell's own config or keys",
     ~r/>\s*~?\/?\.?(ssh|gnupg|bashrc|zshrc|profile)\b/},
    {"a system package removal",
     ~r/\b(apt|apt-get|dnf|yum|pacman|brew)\s+(remove|purge|uninstall|-R)\b/},
    {"crontab replacement", ~r/\bcrontab\s+(-r|-)\b/}
  ]

  @doc "The reasons the command matched, in order; empty for a command the list does not know."
  @spec match(String.t()) :: [String.t()]
  def match(command) when is_binary(command) do
    for {reason, re} <- @patterns, Regex.match?(re, command), do: reason
  end

  @doc "The list, for the docs and the census."
  @spec patterns() :: [{String.t(), Regex.t()}]
  def patterns, do: @patterns
end
