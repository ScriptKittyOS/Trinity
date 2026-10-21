# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestSupport.Ed25519Points do
  @moduledoc """
  Edwards25519 arithmetic for building the Ed25519 vectors of N6 draft v0.1-r7 section 12.1 item 18
  (slice 144): points of small and mixed order, and signatures their holder can make. Written
  apart from `Trinity.N6.Ed25519`, in affine coordinates from RFC 8032 section 5.1.4's formulas,
  so the tests do not check that module against itself.
  """

  import Bitwise

  @p (1 <<< 255) - 19
  @d Integer.mod(-121_665 * :binary.decode_unsigned(:crypto.mod_pow(121_666, @p - 2, @p)), @p)
  @l (1 <<< 252) + 27_742_317_777_372_353_535_851_937_790_883_648_493
  # The base point, and one point of order 8 (RFC 8032; the small-order list of the literature).
  @b "5866666666666666666666666666666666666666666666666666666666666666"
  @t8 "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a"

  def l, do: @l
  def base, do: decode!(Base.decode16!(@b, case: :lower))
  def order8, do: decode!(Base.decode16!(@t8, case: :lower))

  def add({x1, y1}, {x2, y2}) do
    k = mod(@d * x1 * x2 * y1 * y2)
    {mod((x1 * y2 + x2 * y1) * inv(1 + k)), mod((y1 * y2 + x1 * x2) * inv(1 - k))}
  end

  def multiply(0, _point), do: {0, 1}

  def multiply(n, point) do
    half = multiply(n >>> 1, point)
    double = add(half, half)
    if (n &&& 1) == 1, do: add(double, point), else: double
  end

  def encode({x, y}), do: <<bor(y, (x &&& 1) <<< 255)::little-256>>

  # RFC 8032 section 5.1.3, for points the tests build from known-good encodings only.
  def decode!(<<n::little-256>>) do
    y = n &&& (1 <<< 255) - 1
    u = mod(y * y - 1)
    v = mod(@d * y * y + 1)
    x = pow(mod(u * inv(v)), div(@p + 3, 8))

    x =
      if mod(v * x * x - u) == 0,
        do: x,
        else: mod(x * pow(2, div(@p - 1, 4)))

    0 = mod(v * x * x - u)
    if (x &&& 1) == n >>> 255, do: {x, y}, else: {mod(-x), y}
  end

  @doc "The clamped secret scalar of an RFC 8032 seed (section 5.1.5)."
  def scalar(seed) do
    <<h::binary-32, _::binary>> = :crypto.hash(:sha512, seed)
    <<a::little-256>> = h
    bor(a &&& (1 <<< 254) - 8, 1 <<< 254)
  end

  @doc "k = SHA-512(R || A || M) mod L, over the bytes as given."
  def challenge(r, a, message) do
    <<k::little-512>> = :crypto.hash(:sha512, r <> a <> message)
    rem(k, @l)
  end

  defp mod(n), do: Integer.mod(n, @p)
  defp inv(n), do: pow(n, @p - 2)
  defp pow(b, e), do: :crypto.mod_pow(mod(b), e, @p) |> :binary.decode_unsigned()
end
