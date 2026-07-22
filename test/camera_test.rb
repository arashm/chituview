require "test_helper"

class CameraTest < Minitest::Test
  # Mimics the real client: request returns the id its reply will carry, and
  # await_response hands back that reply's Data ({"Ack" => 0, "VideoUrl" => ...}
  # on success). ack: nil models a reply that never arrives.
  class FakeClient
    attr_reader :requests
    def initialize(ack: 0, video_url: nil)
      @ack = ack
      @video_url = video_url
      @requests = []
    end

    def request(cmd, data = {})
      @requests << [cmd, data]
      "request-#{@requests.size}"
    end

    def await_response(_request_id, timeout: nil)
      return nil if @ack.nil?

      reply = { "Ack" => @ack }
      reply["VideoUrl"] = @video_url if @video_url
      reply
    end
  end

  # Records spawn/kill and reports liveness through a flag the lambdas flip, so
  # a test can drive the running? state the way a real process would.
  def recording_camera(players: %w[mpv], **overrides)
    state = { spawned: [], killed: [], alive: false }
    cam = Chituview::Camera.new(
      players: players, which: ->(_) { true },
      spawn: ->(player, url) { state[:spawned] << [player, url]; state[:alive] = true; 4242 },
      kill: ->(handle) { state[:killed] << handle; state[:alive] = false },
      alive: ->(_handle) { state[:alive] },
      **overrides
    )
    [cam, state]
  end

  class FailingClient
    def request(_, _)
      raise IOError, "socket closed"
    end
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

  def test_open_gracefully_handles_client_request_failure
    spawned = []
    cam = Chituview::Camera.new(
      players: %w[mpv ffplay],
      which: ->(p) { p == "ffplay" },
      spawn: ->(player, url) { spawned << [player, url] }
    )

    result = cam.open(FailingClient.new, "1.2.3.4")

    assert_kind_of String, result
    assert_match(/unavailable/, result)
    assert_empty spawned, "spawn should not be called when client.request fails"
  end

  # The printer answers Ack != 0 when it will not start a stream (seen in the
  # wild with more video streams connected than the mainboard allows). Spawning
  # a player then leaves the user staring at a window that never appears.
  def test_open_does_not_spawn_when_printer_refuses
    spawned = []
    cam = Chituview::Camera.new(
      players: %w[mpv], which: ->(_) { true },
      spawn: ->(player, url) { spawned << [player, url] }
    )

    status = cam.open(FakeClient.new(ack: 1), "192.168.50.133")

    assert_empty spawned, "spawned a player for a stream the printer refused"
    assert_match(/refus/i, status)
    assert_match(/1/, status, "should surface the ack code")
  end

  def test_open_reports_when_printer_never_answers
    spawned = []
    cam = Chituview::Camera.new(
      players: %w[mpv], which: ->(_) { true },
      spawn: ->(player, url) { spawned << [player, url] }
    )

    status = cam.open(FakeClient.new(ack: nil), "192.168.50.133")

    assert_empty spawned, "spawned a player without confirmation from the printer"
    assert_match(/answer|respond/i, status)
  end

  # This printer's RTSP server rejects TCP transport ("Nonmatching transport in
  # server reply"), and mpv defaults to TCP, so it must be told to use UDP or it
  # exits instantly with no window — the whole reason the camera never appeared.
  def test_player_command_forces_udp_transport_for_mpv
    cmd = Chituview::Camera.new.send(:player_command, "mpv", "rtsp://x/y")
    assert_includes cmd, "--rtsp-transport=udp"
    assert_equal "rtsp://x/y", cmd.last
  end

  def test_open_uses_the_video_url_the_printer_returns
    cam, state = recording_camera
    cam.open(FakeClient.new(ack: 0, video_url: "rtsp://192.168.50.133:554/live"), "1.2.3.4")
    assert_equal [["mpv", "rtsp://192.168.50.133:554/live"]], state[:spawned]
  end

  def test_open_falls_back_to_template_url_without_one
    cam, state = recording_camera
    cam.open(FakeClient.new(ack: 0), "9.9.9.9")
    assert_equal [["mpv", "rtsp://9.9.9.9:554/video"]], state[:spawned]
  end

  # Every c press used to Enable=1 and spawn again; the printer counts each RTSP
  # connection against its 2-slot limit and only frees a slot on a clean
  # teardown, so a couple of presses exhausted the printer until a reboot.
  def test_open_does_not_start_a_second_stream_while_one_runs
    cam, state = recording_camera
    cam.open(FakeClient.new(ack: 0), "1.2.3.4")
    note = cam.open(FakeClient.new(ack: 0), "1.2.3.4")
    assert_equal 1, state[:spawned].size, "started a second stream while one was already running"
    assert_match(/already open/i, note)
  end

  def test_close_kills_the_player_and_disables_the_camera
    cam, state = recording_camera
    client = FakeClient.new(ack: 0)
    cam.open(client, "1.2.3.4")
    note = cam.close(client)

    assert_equal [4242], state[:killed], "did not kill the player, so the slot never frees"
    refute cam.running?
    assert_equal(
      [[Chituview::Protocol::CMD_CAMERA, { "Enable" => 1 }],
       [Chituview::Protocol::CMD_CAMERA, { "Enable" => 0 }]],
      client.requests
    )
    assert_match(/clos/i, note)
  end

  def test_toggle_opens_then_stops
    cam, state = recording_camera
    client = FakeClient.new(ack: 0)
    cam.toggle(client, "1.2.3.4") # first press opens
    cam.toggle(client, "1.2.3.4") # second press stops
    assert_equal 1, state[:spawned].size
    assert_equal [4242], state[:killed]
    refute cam.running?
  end

  # A player the user closed themselves leaves running? false, so the next press
  # opens a fresh one instead of refusing.
  def test_open_again_after_player_exits_on_its_own
    cam, state = recording_camera
    cam.open(FakeClient.new(ack: 0), "1.2.3.4")
    state[:alive] = false # window closed by the user
    note = cam.open(FakeClient.new(ack: 0), "1.2.3.4")
    assert_equal 2, state[:spawned].size
    assert_match(/opened/i, note)
  end

  # The dashboard calls reap every poll tick so it notices the user closing the
  # player window without a key press, and turns the camera off in response.
  def test_reap_notices_the_player_closed_and_disables_the_camera
    cam, state = recording_camera
    client = FakeClient.new(ack: 0)
    cam.open(client, "1.2.3.4")
    state[:alive] = false # user closed mpv themselves

    note = cam.reap(client)

    assert_equal "camera closed", note
    refute cam.running?
    assert_equal(
      [[Chituview::Protocol::CMD_CAMERA, { "Enable" => 1 }],
       [Chituview::Protocol::CMD_CAMERA, { "Enable" => 0 }]],
      client.requests
    )
  end

  def test_reap_is_silent_while_the_player_runs
    cam, _state = recording_camera
    client = FakeClient.new(ack: 0)
    cam.open(client, "1.2.3.4")
    assert_nil cam.reap(client)
    assert_equal 1, client.requests.size, "reap disabled the camera while it was still up"
  end

  def test_reap_is_silent_when_no_player_was_opened
    cam, = recording_camera
    assert_nil cam.reap(FakeClient.new(ack: 0))
  end

  def test_reap_reports_the_exit_only_once
    cam, state = recording_camera
    client = FakeClient.new(ack: 0)
    cam.open(client, "1.2.3.4")
    state[:alive] = false
    assert_equal "camera closed", cam.reap(client)
    assert_nil cam.reap(client), "reported the same exit twice"
  end

  def test_open_gracefully_handles_spawn_failure
    spawned_calls = []
    cam = Chituview::Camera.new(
      players: %w[mpv ffplay],
      which: ->(p) { p == "ffplay" },
      spawn: ->(player, url) {
        spawned_calls << [player, url]
        raise Errno::ENOENT, "No such file or directory"
      }
    )

    result = cam.open(FakeClient.new, "1.2.3.4")

    assert_kind_of String, result
    assert_match(/could not launch/, result)
    assert_equal 1, spawned_calls.length, "spawn should have been attempted once"
  end
end
