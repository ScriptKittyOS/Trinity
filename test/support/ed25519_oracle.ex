# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestSupport.Ed25519Oracle do
  @moduledoc """
  Whether this runtime verifies Ed25519, asked of `:crypto` directly with RFC 8032 section 7.1's
  test 1 (the empty message under the published key). An oracle for slice 139's tests, independent
  of the code they are about. It answers false in FIPS mode, which refuses Ed25519.
  """

  @pub "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
  @sig "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"

  @spec verifies?() :: boolean()
  def verifies? do
    pub = Base.decode16!(@pub, case: :lower)
    sig = Base.decode16!(@sig, case: :lower)
    :crypto.verify(:eddsa, :none, "", sig, [pub, :ed25519]) == true
  rescue
    _ -> false
  end
end
