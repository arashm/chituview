module Chituview
  class Camera
    VIDEO_URL_TEMPLATE = "rtsp://%s:554/video"
    ACK_TIMEOUT = 2.0

    def initialize(players: %w[mpv ffplay vlc], which: nil, spawn: nil)
      @players = players
      @which = which || method(:installed?)
      @spawn = spawn || method(:spawn_detached)
    end

    def open(client, ip)
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

      url = format(VIDEO_URL_TEMPLATE, ip)
      begin
        @spawn.call(player, url)
      rescue StandardError
        return "could not launch #{player}"
      end
      "camera opened in #{player}"
    end

    def disable(client)
      client.request(Protocol::CMD_CAMERA, { "Enable" => 0 })
    rescue StandardError
      nil
    end

    private

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

    def spawn_detached(player, url)
      pid = Process.spawn(player, url, %i[out err] => File::NULL)
      Process.detach(pid)
    end
  end
end
