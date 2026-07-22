require "test_helper"
require "json"

class DashboardTest < Minitest::Test
  class FakeClient
    attr_reader :inbox, :closed, :requests
    def initialize = (@inbox = Queue.new; @closed = false; @requests = [])
    def request(cmd, data = {}) = @requests << [cmd, data]
    def connected? = true
    def close = @closed = true
  end

  class FakeCamera
    attr_reader :opened, :disabled
    def initialize = (@opened = false; @disabled = false)
    def open(_client, _ip) = (@opened = true; "camera opened in mpv")
    def disable(_client) = @disabled = true
  end

  def status_fixture
    JSON.parse(File.read(File.expand_path("fixtures/status_printing.json", __dir__)))
  end

  def build
    client = FakeClient.new
    camera = FakeCamera.new
    dash = Chituview::Dashboard.new(
      client: client, camera: camera, ip: "192.168.50.133", machine_name: "GK3 Pro"
    )
    [dash, client, camera]
  end

  def strip_ansi(str) = str.gsub(/\e\[[0-9;]*m/, "")

  def test_poll_folds_status_from_inbox_into_view
    dash, client, = build
    client.inbox << { type: :status, payload: status_fixture }

    dash, = dash.handle_poll
    text = strip_ansi(dash.view)

    assert_includes text, "bison - rays.ctb"
    assert_includes text, "1514/1697"
    assert_includes text, "printing"
    assert_equal :live, dash.connection
  end

  def test_poll_marks_reconnecting_on_closed_message
    dash, client, = build
    client.inbox << { type: :closed, payload: {} }
    dash, = dash.handle_poll
    assert_equal :reconnecting, dash.connection
  end

  def test_key_q_quits_and_cleans_up
    dash, client, camera = build
    dash, cmd = dash.handle_key("q")
    assert dash.quitting?
    refute_nil cmd
    assert camera.disabled
    assert client.closed
  end

  def test_key_c_opens_camera_and_sets_note
    dash, _client, camera = build
    dash, = dash.handle_key("c")
    assert camera.opened
    assert_includes dash.status_note, "camera"
  end

  def test_view_renders_idle_without_a_print
    dash, = build
    text = strip_ansi(dash.view)
    assert_includes text, "GK3 Pro"
    assert_includes text, "idle"
  end
end
