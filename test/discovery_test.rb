require "test_helper"

class DiscoveryTest < Minitest::Test
  REPLY = <<~JSON
    {"Id":"x","Data":{"Name":"3D Printer","MachineName":"GK3 GK3Pro",
    "BrandName":"UniFormation","MainboardIP":"192.168.50.133",
    "MainboardID":"82e29f99d60e0100","ProtocolVersion":"V3.0.0",
    "FirmwareVersion":"V1.4.9"}}
  JSON

  def test_parse_reply_extracts_printer_info
    info = Chituview::Discovery.parse_reply(REPLY, "192.168.50.133")
    assert_equal "192.168.50.133", info.ip
    assert_equal "82e29f99d60e0100", info.mainboard_id
    assert_equal "GK3 GK3Pro", info.machine_name
    assert_equal "UniFormation", info.brand
    assert_equal "V1.4.9", info.firmware
    assert_equal "V3.0.0", info.protocol
  end

  def test_parse_reply_returns_nil_on_garbage
    assert_nil Chituview::Discovery.parse_reply("not json", "1.2.3.4")
    assert_nil Chituview::Discovery.parse_reply("{}", "1.2.3.4")
  end

  # Fake UDP socket: records the probe, then yields one reply then timeouts.
  class FakeSocket
    attr_reader :sent
    def initialize(reply, from_ip)
      @reply = reply
      @from_ip = from_ip
      @sent = []
      @served = false
    end
    def setsockopt(*) = nil
    def send(payload, _flags, *_addr) = @sent << payload
    def recvfrom(_len)
      raise IO::TimeoutError if @served

      @served = true
      [@reply, ["AF_INET", 3000, @from_ip, @from_ip]]
    end
    def close = nil
  end

  def test_discover_collects_replies_until_timeout
    sock = FakeSocket.new(REPLY, "192.168.50.133")
    printers = Chituview::Discovery.discover(timeout: 0.2, socket: sock)
    assert_equal 1, printers.size
    assert_equal "82e29f99d60e0100", printers.first.mainboard_id
    assert_equal ["M99999"], sock.sent
  end
end
