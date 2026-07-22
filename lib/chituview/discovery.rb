require "socket"
require "json"

module Chituview
  module Discovery
    PORT = 3000
    PROBE = "M99999"

    PrinterInfo = Struct.new(
      :name, :ip, :mainboard_id, :machine_name, :brand, :firmware, :protocol,
      keyword_init: true
    )

    module_function

    def parse_reply(json_string, ip)
      doc = JSON.parse(json_string)
      data = doc["Data"]
      return nil unless data.is_a?(Hash) && data["MainboardID"]

      PrinterInfo.new(
        name: data["Name"], ip: ip, mainboard_id: data["MainboardID"],
        machine_name: data["MachineName"], brand: data["BrandName"],
        firmware: data["FirmwareVersion"], protocol: data["ProtocolVersion"]
      )
    rescue JSON::ParserError
      nil
    end

    def discover(timeout: 3, socket: nil, broadcast: "255.255.255.255")
      sock = socket || build_socket(broadcast: true)
      sock.send(PROBE, 0, broadcast, PORT)
      collect(sock, timeout)
    ensure
      sock.close if socket.nil? && sock
    end

    def probe(ip, timeout: 2, socket: nil)
      sock = socket || build_socket(broadcast: false)
      sock.send(PROBE, 0, ip, PORT)
      collect(sock, timeout).first
    ensure
      sock.close if socket.nil? && sock
    end

    # Real sockets get a receive timeout so recvfrom can't block forever; the
    # loop below then relies on recvfrom raising IO::TimeoutError to stop. The
    # test's FakeSocket mimics this by raising IO::TimeoutError after one reply.
    def build_socket(broadcast:)
      sock = UDPSocket.new
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true) if broadcast
      timeval = [0, 300_000].pack("l_2") # 0.3s
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, timeval)
      sock
    end

    def collect(sock, timeout)
      deadline = now + timeout
      found = {}
      loop do
        break if now >= deadline

        data, addr = begin
          sock.recvfrom(8192)
        rescue IO::TimeoutError, Errno::EAGAIN
          nil
        end
        break if data.nil?

        info = parse_reply(data, addr[3])
        found[info.mainboard_id] = info if info
      end
      found.values
    end

    # Monotonic clock (Process.clock_gettime is allowed at runtime).
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
