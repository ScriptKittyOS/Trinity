# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Tier3.Verifier do
  @moduledoc """
  The two signature checks of the Tier 3 import path (slice 134, D6), offline, against keys the
  operator holds: **cosign** over the OCI artifact as delivered, **OMS** (OpenSSF Model Signing)
  over the model files once unpacked.

  The implementation that ships is `Trinity.Memory.Tier3.Verifier.CLI`, which runs the reference
  programs (`cosign`, `model_signing`). Trinity does not carry a signature verifier of its own:
  one would be a second thing to trust and audit (slice 134 NOTES, decision 10). The behaviour
  exists so the import path's own checks can be tested on a machine without the programs.
  """

  @doc "`:ok` when the OCI layout's signature verifies against the cosign public key, offline."
  @callback cosign(layout :: Path.t(), public_key :: Path.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "`:ok` when the OMS signature over the model directory verifies against the public key."
  @callback oms(model_dir :: Path.t(), signature :: Path.t(), public_key :: Path.t(), keyword()) ::
              :ok | {:error, term()}
end
