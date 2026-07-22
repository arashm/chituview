require "test_helper"
require "websocket"
require "json"

class ClientTest < Minitest::Test
  # Records writes; never used for reading in these unit tests.
  class RecordingSocket
    attr_reader :written
    def initialize = @written = +"".b
    def write(bytes) = @written << bytes
    def readpartial(_n) = raise IOError, "not used"
    def close = nil
  end

  def client
    sock = RecordingSocket.new
    c = Chituview::Client.new(
      ip: "1.2.3.4", mainboard_id: "MB",
      socket_factory: -> { sock }
    )
    # Inject the socket without doing a real handshake.
    c.instance_variable_set(:@socket, sock)
    c.instance_variable_set(:@ws_version, 13)
    [c, sock]
  end

  def test_request_writes_a_websocket_text_frame_with_the_envelope
    c, sock = client
    c.request(Chituview::Protocol::CMD_CAMERA, { "Enable" => 1 })

    # Decode what was written back into a message using the websocket gem.
    incoming = WebSocket::Frame::Incoming::Server.new(version: 13)
    incoming << sock.written
    frame = incoming.next
    refute_nil frame, "expected a decodable websocket frame"

    env = JSON.parse(frame.data)
    assert_equal 386, env["Data"]["Cmd"]
    assert_equal({ "Enable" => 1 }, env["Data"]["Data"])
    assert_equal "sdcp/request/MB", env["Topic"]
    assert_equal "MB", env["Data"]["MainboardID"]
  end

  def test_feed_parses_status_frames_into_inbox
    c, = client
    status = {
      "Status" => { "PrintInfo" => { "Filename" => "a.ctb" } },
      "Topic" => "sdcp/status/MB"
    }
    # Build a server->client text frame the way the printer would.
    out = WebSocket::Frame::Outgoing::Server.new(
      version: 13, data: JSON.generate(status), type: :text
    )
    c.feed(out.to_s)

    msg = c.inbox.pop
    assert_equal :status, msg[:type]
    assert_equal "a.ctb", msg[:payload].dig("Status", "PrintInfo", "Filename")
  end

  def test_feed_ignores_non_json_frames
    c, = client
    out = WebSocket::Frame::Outgoing::Server.new(version: 13, data: "garbage", type: :text)
    c.feed(out.to_s)
    assert c.inbox.empty?
  end

  def test_backoff_is_capped_exponential
    c, = client
    assert_in_delta 0.5, c.backoff_delay(0), 0.0001
    assert_in_delta 1.0, c.backoff_delay(1), 0.0001
    assert_in_delta 2.0, c.backoff_delay(2), 0.0001
    # capped at max_backoff (default 8.0)
    assert_in_delta 8.0, c.backoff_delay(10), 0.0001
  end
end
