defmodule SampleAuth do
  alias SampleUser

  def login(email, password) do
    with {:ok, user} <- SampleUser.find_by_email(email),
         true <- verify_password(user, password) do
      {:ok, user}
    end
  end

  def verify_token(token) do
    case decode_jwt(token) do
      {:ok, claims} -> {:ok, claims}
      _ -> {:error, :invalid_token}
    end
  end

  defp verify_password(user, password) do
    user.password_hash == hash(password)
  end

  defp hash(str), do: :crypto.hash(:sha256, str)
  defp decode_jwt(_token), do: {:ok, %{sub: "user_123"}}
end
