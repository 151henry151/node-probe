defmodule NodeProbe.Bitcoin.RpcBehaviour do
  @callback call(method :: String.t(), params :: list()) ::
              {:ok, term()} | {:error, term()}
end
