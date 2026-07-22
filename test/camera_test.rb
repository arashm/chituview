require "test_helper"

class CameraTest < Minitest::Test
  class FakeClient
    attr_reader :requests
    def initialize = @requests = []
    def request(cmd, data = {}) = @requests << [cmd, data]
  end

  def test_open_enables_camera_and_spawns_first_available_player
    spawned = []
    cam = Chituview::Camera.new(
      players: %w[mpv ffplay vlc],
      which: ->(p) { p == "ffplay" }, # mpv missing, ffplay present
      spawn: ->(player, url) { spawned << [player, url] }
    )
    client = FakeClient.new

    status = cam.open(client, "192.168.50.133")

    assert_equal [[Chituview::Protocol::CMD_CAMERA, { "Enable" => 1 }]], client.requests
    assert_equal [["ffplay", "rtsp://192.168.50.133:554/video"]], spawned
    assert_match(/ffplay/, status)
  end

  def test_open_reports_when_no_player_available
    cam = Chituview::Camera.new(
      players: %w[mpv ffplay vlc], which: ->(_) { false },
      spawn: ->(_, _) { flunk "should not spawn" }
    )
    status = cam.open(FakeClient.new, "1.2.3.4")
    assert_match(/no.*player/i, status)
  end

  def test_disable_sends_enable_zero
    client = FakeClient.new
    Chituview::Camera.new.disable(client)
    assert_equal [[Chituview::Protocol::CMD_CAMERA, { "Enable" => 0 }]], client.requests
  end
end
