defmodule NodeProbe.Bitcoin.RpcTest do
  use ExUnit.Case, async: true

  import Mox

  Mox.defmock(NodeProbe.Bitcoin.RpcMock, for: NodeProbe.Bitcoin.RpcBehaviour)

  setup :verify_on_exit!

  describe "NodeProbe.Bitcoin.RpcBehaviour" do
    test "behaviour defines call/2 callback" do
      callbacks = NodeProbe.Bitcoin.RpcBehaviour.behaviour_info(:callbacks)
      assert {:call, 2} in callbacks
    end
  end

  describe "Rpc.call/2 via mock" do
    test "returns ok with result on success" do
      NodeProbe.Bitcoin.RpcMock
      |> expect(:call, fn "getblockchaininfo", [] ->
        {:ok, %{"chain" => "main", "blocks" => 840_000}}
      end)

      assert {:ok, %{"chain" => "main", "blocks" => 840_000}} =
               NodeProbe.Bitcoin.RpcMock.call("getblockchaininfo", [])
    end

    test "returns error on RPC failure" do
      NodeProbe.Bitcoin.RpcMock
      |> expect(:call, fn "getblock", [_hash] ->
        {:error, {:rpc_error, -5, "Block not found"}}
      end)

      assert {:error, {:rpc_error, -5, "Block not found"}} =
               NodeProbe.Bitcoin.RpcMock.call("getblock", ["deadbeef"])
    end

    test "returns error on unauthorized" do
      NodeProbe.Bitcoin.RpcMock
      |> expect(:call, fn _method, _params ->
        {:error, :unauthorized}
      end)

      assert {:error, :unauthorized} = NodeProbe.Bitcoin.RpcMock.call("getblockchaininfo", [])
    end
  end

  describe "Rpc auth resolution" do
    test "prefers cookie file when it exists" do
      cookie_path = System.tmp_dir!() |> Path.join("test_rpc_#{System.unique_integer()}.cookie")
      File.write!(cookie_path, "__cookie__:secrettoken\n")

      Application.put_env(:node_probe, :bitcoin_cookie_path, cookie_path)
      Application.put_env(:node_probe, :bitcoin_rpc_user, "user")
      Application.put_env(:node_probe, :bitcoin_rpc_pass, "pass")

      on_exit(fn ->
        File.rm(cookie_path)
        Application.delete_env(:node_probe, :bitcoin_cookie_path)
        Application.delete_env(:node_probe, :bitcoin_rpc_user)
        Application.delete_env(:node_probe, :bitcoin_rpc_pass)
      end)

      assert NodeProbe.Bitcoin.Rpc.resolve_auth() == "__cookie__:secrettoken"
    end

    test "falls back to user/pass when cookie file missing" do
      Application.put_env(:node_probe, :bitcoin_cookie_path, "/nonexistent/.cookie")
      Application.put_env(:node_probe, :bitcoin_rpc_user, "myuser")
      Application.put_env(:node_probe, :bitcoin_rpc_pass, "mypass")

      on_exit(fn ->
        Application.delete_env(:node_probe, :bitcoin_cookie_path)
        Application.delete_env(:node_probe, :bitcoin_rpc_user)
        Application.delete_env(:node_probe, :bitcoin_rpc_pass)
      end)

      assert NodeProbe.Bitcoin.Rpc.resolve_auth() == "myuser:mypass"
    end
  end
end
