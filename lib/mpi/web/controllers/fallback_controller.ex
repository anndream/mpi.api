defmodule MPI.Web.FallbackController do
  @moduledoc false
  use MPI.Web, :controller

  def call(conn, nil) do
    conn
    |> put_status(:not_found)
    |> render(EView.Views.PhoenixError, :"404")
  end

  def call(conn, %Ecto.Changeset{valid?: false} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(EView.Views.ValidationError, :"422", changeset)
  end
end
