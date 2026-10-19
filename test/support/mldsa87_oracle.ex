# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestSupport.MLDSA87Oracle do
  @moduledoc """
  Whether this runtime can generate, sign and verify ML-DSA-87, asked of `:crypto` directly.

  An oracle for slice 137's tests, deliberately independent of `Trinity.Crypto.Preflight`, the code
  those tests are about. It answers false on a runtime linked to OpenSSL older than 3.5 and, in
  FIPS mode, wherever the provider refuses ML-DSA.
  """

  @spec signs?() :: boolean()
  def signs? do
    {pub, priv} = :crypto.generate_key(:mldsa87, [])
    sig = :crypto.sign(:mldsa87, :none, "slice 137 oracle", priv)
    :crypto.verify(:mldsa87, :none, "slice 137 oracle", sig, pub) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
