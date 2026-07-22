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
      collect(sock, timeout, stop_on_first: true).first
    ensure
      sock.close if socket.nil? && sock
    end

    # Real sockets get a receive timeout so recvfrom can't block forever; the
    # loop below then relies on recvfrom raising IO::TimeoutError to stop. The
    # test's FakeSocket mimics this by raising IO::TimeoutError after one reply.
    #
    # This must be IO#timeout, not SO_RCVTIMEO: Ruby waits for readability with
    # its own scheduler before calling recvfrom(2), so the socket option never
    # gets a chance to fire and recvfrom blocks forever.
    def build_socket(broadcast:)
      sock = UDPSocket.new
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true) if broadcast
      sock.timeout = 0.3
      sock
    end

    # Listens for the whole timeout window so printers that are slow to answer
    # still get counted. Each receive only waits build_socket's 0.3s, so a quiet
    # stretch means "nothing yet", not "nobody is out there" — keep going until
    # the deadline. Probing a known IP passes stop_on_first to return the moment
    # that one printer answers instead of waiting out the window.
    def collect(sock, timeout, stop_on_first: false)
      deadline = now + timeout
      found = {}
      while now < deadline
        begin
          data, addr = sock.recvfrom(8192)
        rescue IO::TimeoutError, Errno::EAGAIN
          next
        end

        info = parse_reply(data, addr[3])
        next unless info

        found[info.mainboard_id] = info
        break if stop_on_first
      end
      found.values
    end

    # Monotonic clock (Process.clock_gettime is allowed at runtime).
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
