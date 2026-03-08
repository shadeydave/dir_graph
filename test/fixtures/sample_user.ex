defmodule SampleUser do
  def find_by_email(email) do
    {:ok, %{email: email, password_hash: "abc123"}}
  end

  def update_password(user, new_hash) do
    %{user | password_hash: new_hash}
  end

  def list_all do
    []
  end
end
