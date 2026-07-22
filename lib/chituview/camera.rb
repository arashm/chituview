module Chituview
  class Camera
    VIDEO_URL_TEMPLATE = "rtsp://%s:554/video"
    ACK_TIMEOUT = 2.0

    def initialize(players: %w[mpv ffplay vlc], which: nil, spawn: nil, kill: nil, alive: nil)
      @players = players
      @which = which || method(:installed?)
      @spawn = spawn || method(:spawn_detached)
      @kill = kill || method(:terminate)
      @alive = alive || method(:process_alive?)
      @handle = nil
      @player = nil
    end

    # One key press: open the camera if it is closed, close it if it is open.
    # Gives the user a way to stop a stream without quitting the whole app.
    def toggle(client, ip)
      running? ? close(client) : open(client, ip)
    end

    def open(client, ip)
      return "camera already open in #{@player}" if running?

      request_id = begin
        client.request(Protocol::CMD_CAMERA, { "Enable" => 1 })
      rescue StandardError
        return "camera unavailable (printer not reachable)"
      end

      # Enabling is fire-and-forget over the websocket, so without waiting for
      # the ack we would launch a player against a stream the printer never
      # started — it exits immediately and the user sees nothing happen.
      reply = client.await_response(request_id, timeout: ACK_TIMEOUT)
      return "camera did not answer" if reply.nil?

      ack = reply["Ack"].to_i
      return refusal(ack) unless ack.zero?

      player = @players.find { |p| @which.call(p) }
      return "no video player found (install mpv, ffplay, or vlc)" unless player

      url = reply["VideoUrl"] || format(VIDEO_URL_TEMPLATE, ip)
      begin
        @handle = @spawn.call(player, url)
      rescue StandardError
        @handle = nil
        return "could not launch #{player}"
      end
      @player = player
      "camera opened in #{player}"
    end

    # Stops the local player first: the printer's video-slot count only drops
    # when the RTSP client disconnects (Enable=0 alone does not free it), so a
    # player left running holds a slot indefinitely. Killing it is necessary but
    # may not be sufficient — an abrupt exit can skip the graceful RTSP TEARDOWN
    # and the slot then lingers until the printer times the session out.
    def close(client)
      kill_player
      disable(client)
      "camera closed"
    end

    # Called each poll tick so the app notices the user closing the player
    # window on their own — otherwise its state stays stale until the next key
    # press. Returns the status note once, when it first sees the player gone
    # (and turns the camera off), and nil otherwise so it is cheap to call often.
    def reap(client)
      return nil unless @handle
      return nil if @alive.call(@handle)

      clear_player
      disable(client)
      "camera closed"
    end

    def disable(client)
      client.request(Protocol::CMD_CAMERA, { "Enable" => 0 })
    rescue StandardError
      nil
    end

    def running?
      !!(@handle && @alive.call(@handle))
    end

    private

    def kill_player
      @kill.call(@handle) if @handle
    ensure
      clear_player
    end

    def clear_player
      @handle = nil
      @player = nil
    end

    # Ack 0 means the stream started; every other code is a refusal. The one
    # seen in the wild is 1, returned while the mainboard reported more video
    # streams connected than MaximumVideoStreamAllowed — those slots are only
    # released by the printer, so a reboot is usually what clears it.
    def refusal(ack)
      "printer refused the camera (ack #{ack}); check its video stream slots"
    end

    def installed?(player)
      system("command -v #{player} > /dev/null 2>&1")
    end

    # This printer's RTSP server rejects the TCP interleaved transport
    # ("Nonmatching transport in server reply"), and mpv defaults to TCP, so it
    # must be told to use UDP or it exits immediately without a window. ffplay
    # and vlc default to UDP already; the flag keeps them explicit.
    def player_command(player, url)
      case player
      when "mpv"    then ["mpv", "--rtsp-transport=udp", url]
      when "ffplay" then ["ffplay", "-rtsp_transport", "udp", url]
      else [player, url]
      end
    end

    def spawn_detached(player, url)
      pid = Process.spawn(*player_command(player, url), %i[out err] => File::NULL)
      Process.detach(pid)
      pid
    end

    def terminate(pid)
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      nil
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
  end
end
