defmodule NodeProbeWeb.PageController do
  use NodeProbeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
