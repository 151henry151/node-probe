defmodule NodeProbe.Bitcoin.Rpc do
  @behaviour NodeProbe.Bitcoin.RpcBehaviour

  @moduledoc """
  Thin HTTP client for Bitcoin Core JSON-RPC.

  Supports both cookie authentication (preferred when bitcoind runs locally)
  and username/password authentication. Cookie auth is attempted first; if the
  cookie file is missing or unreadable, user/pass credentials are used.
  """

  require Logger

  @impl NodeProbe.Bitcoin.RpcBehaviour
  def call(method, params \\ []) do
    url = config(:bitcoin_rpc_url)
    auth = resolve_auth()

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => params
      })

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Basic " <> Base.encode64(auth)}
    ]

    case Finch.build(:post, url, headers, body) |> Finch.request(NodeProbe.Finch) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        parse_response(resp_body)

      {:ok, %Finch.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        case parse_response(resp_body) do
          {:error, _} = err -> err
          {:ok, _} -> {:error, {:http_error, status}}
        end

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => nil, "result" => result}} ->
        {:ok, result}

      {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
        {:error, {:rpc_error, code, msg}}

      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  @doc false
  def resolve_auth do
    cookie_path = config(:bitcoin_cookie_path) |> Path.expand()

    case File.read(cookie_path) do
      {:ok, cookie} ->
        String.trim(cookie)

      {:error, _} ->
        user = config(:bitcoin_rpc_user)
        pass = config(:bitcoin_rpc_pass)
        "#{user}:#{pass}"
    end
  end

  defp config(key), do: Application.get_env(:node_probe, key)
end
