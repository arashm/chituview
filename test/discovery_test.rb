require "test_helper"
require "timeout"

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

  # Answers only after a couple of quiet receives, like a printer that is slow
  # to get around to replying.
  class SlowSocket
    def initialize(reply, from_ip, quiet_receives)
      @reply = reply
      @from_ip = from_ip
      @quiet = quiet_receives
      @served = false
    end
    def setsockopt(*) = nil
    def send(*) = nil
    def recvfrom(_len)
      raise IO::TimeoutError if @served
      (@quiet -= 1) >= 0 and raise IO::TimeoutError

      @served = true
      [@reply, ["AF_INET", 3000, @from_ip, @from_ip]]
    end
    def close = nil
  end

  def test_collect_keeps_listening_through_quiet_stretches
    sock = SlowSocket.new(REPLY, "192.168.50.133", 2)
    printers = Chituview::Discovery.discover(timeout: 0.5, socket: sock)
    assert_equal 1, printers.size, "gave up at the first silent receive"
  end

  def test_probe_returns_as_soon_as_a_printer_answers
    sock = FakeSocket.new(REPLY, "192.168.50.133")
    started = Chituview::Discovery.now
    info = Chituview::Discovery.probe("192.168.50.133", timeout: 30, socket: sock)
    assert_equal "82e29f99d60e0100", info.mainboard_id
    assert_operator Chituview::Discovery.now - started, :<, 5, "waited out the full window"
  end

  # FakeSocket only *mimics* a receive timeout; this exercises a real socket to
  # prove build_socket actually gives us one. Nothing ever answers on this port,
  # so collect must come back empty rather than block forever.
  def test_real_socket_collect_returns_when_nothing_replies
    sock = Chituview::Discovery.build_socket(broadcast: false)
    sock.bind("127.0.0.1", 0)
    started = Chituview::Discovery.now
    found = Timeout.timeout(10) { Chituview::Discovery.collect(sock, 0.5) }
    assert_empty found
    assert_operator Chituview::Discovery.now - started, :<, 5
  ensure
    sock&.close
  end
end
