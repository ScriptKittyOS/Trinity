# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.AuthHTML do
  @moduledoc "The login pages (slice 136): the shared token form, a refused login, a refused role."
  use TrinityWeb, :html

  embed_templates "auth_html/*"
end
