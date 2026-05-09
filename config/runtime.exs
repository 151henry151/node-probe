import Config

config :node_probe,
  bitcoin_rpc_url: System.get_env("BITCOIN_RPC_URL", "http://127.0.0.1:8332"),
  bitcoin_rpc_user: System.get_env("BITCOIN_RPC_USER", "bitcoin"),
  bitcoin_rpc_pass: System.get_env("BITCOIN_RPC_PASS", ""),
  bitcoin_cookie_path: System.get_env("BITCOIN_COOKIE_PATH", "~/.bitcoin/.cookie"),
  ebpf_loader_path:
    System.get_env("EBPF_LOADER_PATH", "./priv/ebpf/target/release/node-probe-loader"),
  ebpf_enabled: System.get_env("EBPF_ENABLED", "true") == "true",
  p2p_tap_enabled: System.get_env("P2P_TAP_ENABLED", "false") == "true",
  rpc_poll_interval_ms: String.to_integer(System.get_env("RPC_POLL_MS", "2000")),
  lite_mode: System.get_env("LITE_MODE", "false") == "true"

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/node_probe start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :node_probe, NodeProbeWeb.Endpoint, server: true
end

unless config_env() == :prod do
  config :node_probe, NodeProbeWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  # Public URL path when served behind nginx under a prefix (e.g. /node-probe).
  # Set PHX_PATH=node-probe (no leading slash).
  phx_path =
    case System.get_env("PHX_PATH") do
      nil -> nil
      "" -> nil
      p -> "/" <> String.trim(p, "/")
    end

  url_opts = [host: host, port: 443, scheme: "https"]

  url_opts =
    if phx_path do
      Keyword.put(url_opts, :path, phx_path)
    else
      url_opts
    end

  http_ip =
    if System.get_env("PHX_BIND") == "all" do
      {0, 0, 0, 0, 0, 0, 0, 0}
    else
      {127, 0, 0, 1}
    end

  config :node_probe, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :node_probe, NodeProbeWeb.Endpoint,
    url: url_opts,
    http: [
      ip: http_ip,
      port: port
    ],
    secret_key_base: secret_key_base,
    check_origin: [
      "https://hromp.com",
      "https://www.hromp.com"
    ]

  # ## SSL Support
  #
  # Terminated at nginx; see `force_ssl` in config/prod.exs for X-Forwarded-Proto.
end
