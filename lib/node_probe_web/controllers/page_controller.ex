defmodule NodeProbeWeb.PageController do
  use NodeProbeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def dashboard_redirect(conn, _params) do
    redirect(conn, to: ~p"/")
  end
end
