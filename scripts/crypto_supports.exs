# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Prints what this runtime's crypto supports, one item per line, sorted, so two runs of the
# same file can be diffed (slice 003, docs/fips-leg.md). Plain `elixir`, no Mix: the FIPS leg
# runs it once with FIPS mode off and the suite runs it once with the mode on, and the
# committed files under docs/fips-leg/ are what those two runs printed.
#
#   elixir scripts/crypto_supports.exs
#
# The first lines name the mode and the library, so a listing can never be read without its
# provenance. `crypto:supports/0` is the population; nothing here is a hand list.

info = :crypto.info()

header = [
  "fips_mode: #{inspect(:crypto.info_fips())}",
  "fips_provider_available: #{inspect(Map.get(info, :fips_provider_available))}",
  "cryptolib_version_linked: #{List.to_string(Map.get(info, :cryptolib_version_linked, ~c"?"))}",
  "otp_crypto_version: #{List.to_string(Map.get(info, :otp_crypto_version, ~c"?"))}"
]

body =
  for {category, items} <- :crypto.supports(),
      item <- items,
      do: "#{category}: #{inspect(item)}"

IO.puts(Enum.join(header ++ Enum.sort(body), "\n"))
