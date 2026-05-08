defmodule NodeProbe.Bitcoin.Types do
  defmodule Block do
    @enforce_keys [:hash]
    defstruct [
      :hash,
      :height,
      :timestamp,
      :tx_count,
      :total_fees_sat,
      :weight,
      :median_fee_rate,
      :spend_type_breakdown
    ]
  end

  defmodule Tx do
    @enforce_keys [:txid]
    defstruct [
      :txid,
      :fee_sat,
      :fee_rate_svb,
      :weight,
      :input_count,
      :output_count,
      :spend_types,
      :total_output_sat
    ]
  end

  defmodule Peer do
    @enforce_keys [:id]
    defstruct [
      :id,
      :addr,
      :version,
      :subver,
      :services,
      :ping_ms,
      :bytes_sent,
      :bytes_recv,
      :connected_since,
      :inbound
    ]
  end

  defmodule MempoolEntry do
    @enforce_keys [:txid]
    defstruct [
      :txid,
      :fee_sat,
      :fee_rate_svb,
      :weight,
      :time,
      :height
    ]
  end
end
