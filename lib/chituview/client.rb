require "socket"
require "json"
require "securerandom"
require "websocket"

module Chituview
  class Client
    READ_ERRORS = [IOError, EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNREFUSED, SocketError].freeze

    attr_reader :inbox

    def initialize(ip:, mainboard_id:, port: 3030, socket_factory: nil, max_backoff: 8.0)
      @ip = ip
      @port = port
      @mainboard_id = mainboard_id
      @socket_factory = socket_factory || -> { TCPSocket.new(ip, port) }
      @max_backoff = max_backoff
      @inbox = Queue.new
      @socket = nil
      @ws_version = nil
      @reader = nil
      @incoming = nil
      @closing = false
    end

    def connect
      establish
      start_reader
      self
    end

    def connected? = !@socket.nil?

    def request(cmd, data = {})
      envelope = Protocol.request(
        cmd: cmd, mainboard_id: @mainboard_id, data: data,
        id: SecureRandom.hex(16), request_id: SecureRandom.hex(16),
        timestamp: Time.now.to_i
      )
      frame = WebSocket::Frame::Outgoing::Client.new(
        version: @ws_version || 13, data: JSON.generate(envelope), type: :text
      )
      @socket.write(frame.to_s)
    end

    # Parse raw bytes from the socket into inbox messages.
    def feed(bytes)
      @incoming ||= WebSocket::Frame::Incoming::Client.new(version: @ws_version || 13)
      @incoming << bytes
      while (frame = @incoming.next)
        push_message(frame.data)
      end
    end

    # Capped exponential backoff: 0.5, 1, 2, 4, ... up to max_backoff.
    def backoff_delay(attempt)
      [0.5 * (2**attempt), @max_backoff].min
    end

    def close
      @closing = true
      @reader&.kill
      @socket&.close
    rescue IOError
      # already closed
    ensure
      @socket = nil
    end

    private

    # Open a socket, perform the WS handshake, reset the incoming frame parser.
    def establish
      @socket = @socket_factory.call
      handshake!
      @incoming = WebSocket::Frame::Incoming::Client.new(version: @ws_version)
    end

    def push_message(text)
      doc = JSON.parse(text)
      @inbox << { type: Protocol.classify(doc["Topic"]), payload: doc }
    rescue JSON::ParserError
      # ignore non-JSON frames
    end

    def handshake!
      hs = WebSocket::Handshake::Client.new(url: "ws://#{@ip}:#{@port}/websocket")
      @socket.write(hs.to_s)
      hs << @socket.readpartial(4096) until hs.finished?
      raise Error, "WebSocket handshake failed" unless hs.valid?

      @ws_version = hs.version
    end

    def start_reader
      @reader = Thread.new do
        loop do
          break if @closing

          begin
            feed(@socket.readpartial(8192))
          rescue *READ_ERRORS
            break if @closing

            @inbox << { type: :closed, payload: {} }
            break unless reconnect_with_backoff
          end
        end
      end
      @reader.abort_on_exception = false
    end

    # Retry establish() with capped exponential backoff. Returns true once
    # reconnected (and re-requests a status snapshot), false if we're closing.
    def reconnect_with_backoff
      attempt = 0
      until @closing
        sleep(backoff_delay(attempt))
        return false if @closing

        begin
          establish
          request(Protocol::CMD_STATUS)
          return true
        rescue *READ_ERRORS, Error
          attempt += 1
        end
      end
      false
    end
  end
end
