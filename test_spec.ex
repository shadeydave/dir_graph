defmodule AntiGravity.Auth_Demo do
  @moduledoc "Main authentication module that parses and verifies OAuth tokens."

  def login(token) do
    {:ok, parsed} = JwtParser.decode(token)
    DB.Session.verify(parsed)
  end
end
