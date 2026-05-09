defmodule NodeProbeWeb.Router do
  use NodeProbeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NodeProbeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NodeProbeWeb do
    pipe_through :browser

    live "/", DashboardLive, :index

    get "/block", PageController, :dashboard_redirect
    get "/peers", PageController, :dashboard_redirect
    get "/mempool", PageController, :dashboard_redirect
    get "/io", PageController, :dashboard_redirect
    get "/anomalies", PageController, :dashboard_redirect
  end
end
