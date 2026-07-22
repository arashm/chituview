module Chituview
  class Camera
    VIDEO_URL_TEMPLATE = "rtsp://%s:554/video"

    def initialize(players: %w[mpv ffplay vlc], which: nil, spawn: nil)
      @players = players
      @which = which || method(:installed?)
      @spawn = spawn || method(:spawn_detached)
    end

    def open(client, ip)
      client.request(Protocol::CMD_CAMERA, { "Enable" => 1 })
      player = @players.find { |p| @which.call(p) }
      return "no video player found (install mpv, ffplay, or vlc)" unless player

      url = format(VIDEO_URL_TEMPLATE, ip)
      @spawn.call(player, url)
      "camera opened in #{player}"
    end

    def disable(client)
      client.request(Protocol::CMD_CAMERA, { "Enable" => 0 })
    rescue StandardError
      nil
    end

    private

    def installed?(player)
      system("command -v #{player} > /dev/null 2>&1")
    end

    def spawn_detached(player, url)
      pid = Process.spawn(player, url, %i[out err] => File::NULL)
      Process.detach(pid)
    end
  end
end
