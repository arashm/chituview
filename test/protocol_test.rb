require "test_helper"

class ProtocolTest < Minitest::Test
  def test_request_builds_exact_sdcp_envelope
    env = Chituview::Protocol.request(
      cmd: Chituview::Protocol::CMD_STATUS,
      mainboard_id: "82e29f99d60e0100",
      data: {},
      id: "aa", request_id: "bb", timestamp: 1784734565
    )

    assert_equal "aa", env["Id"]
    assert_equal "sdcp/request/82e29f99d60e0100", env["Topic"]
    assert_equal 0, env["Data"]["Cmd"]
    assert_equal({}, env["Data"]["Data"])
    assert_equal "bb", env["Data"]["RequestID"]
    assert_equal "82e29f99d60e0100", env["Data"]["MainboardID"]
    assert_equal 1784734565, env["Data"]["TimeStamp"]
    assert_equal 0, env["Data"]["From"]
  end

  def test_request_passes_command_data_through
    env = Chituview::Protocol.request(
      cmd: Chituview::Protocol::CMD_CAMERA, mainboard_id: "x",
      data: { "Enable" => 1 }, id: "i", request_id: "r", timestamp: 1
    )
    assert_equal 386, env["Data"]["Cmd"]
    assert_equal({ "Enable" => 1 }, env["Data"]["Data"])
  end

  def test_classify_maps_topics
    assert_equal :status,     Chituview::Protocol.classify("sdcp/status/abc")
    assert_equal :attributes, Chituview::Protocol.classify("sdcp/attributes/abc")
    assert_equal :response,   Chituview::Protocol.classify("sdcp/response/abc")
    assert_equal :error,      Chituview::Protocol.classify("sdcp/error/abc")
    assert_equal :unknown,    Chituview::Protocol.classify("sdcp/nope/abc")
    assert_equal :unknown,    Chituview::Protocol.classify(nil)
  end
end
