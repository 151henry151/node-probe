defmodule NodeProbeWeb.FeeFormatTest do
  use ExUnit.Case, async: true

  alias NodeProbeWeb.FeeFormat

  test "converts BTC/kB relay floor to sat/vB (1 sat/vB default relay)" do
    assert_in_delta FeeFormat.mempool_min_fee_sat_vb(0.00001), 1.0, 1.0e-9
  end

  test "formats small sat/vB without scientific notation" do
    assert FeeFormat.format_sat_per_vb(1.0e-6) != "1.0e-6"
    assert FeeFormat.format_sat_per_vb(1.0e-6) =~ "0.000001"
  end

  test "formats typical mempool min fee for display" do
    sat = FeeFormat.mempool_min_fee_sat_vb(1.0e-8)
    out = FeeFormat.format_sat_per_vb(sat)
    assert out =~ "0.001"
  end
end
