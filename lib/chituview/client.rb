require "socket"
require "json"
require "securerandom"
require "websocket"

module Chituview
  class Client
    READ_ERRORS = [IOError, EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNREFUSED, SocketError].freeze

    # Replies nobody waits for would pile up forever, so only the newest few are
    # kept — long enough for an await_response call to pick its own out.
    RESPONSE_CACHE_LIMIT = 32

    attr_reader :inbox

    def initialize(ip:, mainboard_id:, port: 3030, socket_factory: nil, max_backoff: 8.0)
      @ip = ip
      @port = port
      @mainboard_id = mainboard_id
      @socket_factory = socket_factory || -> { TCPSocket.new(ip, port) }
      @max_backoff = max_backoff
      @inbox = Queue.new
      @responses = {}
      @response_lock = Mutex.new
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

    # Returns the RequestID the printer will echo back, so callers that care
    # whether the command was accepted can await_response on it.
    def request(cmd, data = {})
      request_id = SecureRandom.hex(16)
      envelope = Protocol.request(
        cmd: cmd, mainboard_id: @mainboard_id, data: data,
        id: SecureRandom.hex(16), request_id: request_id,
        timestamp: Time.now.to_i
      )
      frame = WebSocket::Frame::Outgoing::Client.new(
        version: @ws_version || 13, data: JSON.generate(envelope), type: :text
      )
      @socket.write(frame.to_s)
      request_id
    end

    # Waits for the printer's reply to request_id and returns its Data hash
    # (`{"Ack" => 0}` on success), or nil if nothing arrived in time. The reader
    # thread files replies as they land, so this only has to poll for one.
    def await_response(request_id, timeout: 2.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        reply = @response_lock.synchronize { @responses.delete(request_id) }
        return reply if reply
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.02
      end
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
      type = Protocol.classify(doc["Topic"])
      file_response(doc) if type == :response
      @inbox << { type: type, payload: doc }
    rescue JSON::ParserError
      # ignore non-JSON frames
    end

    # A response envelope nests the interesting part: Data.Data holds the Ack,
    # Data.RequestID says which request it answers.
    def file_response(doc)
      envelope = doc["Data"]
      request_id = envelope.is_a?(Hash) && envelope["RequestID"]
      return unless request_id

      @response_lock.synchronize do
        @responses[request_id] = envelope["Data"]
        @responses.shift while @responses.size > RESPONSE_CACHE_LIMIT
      end
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
          rescue StandardError
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
        rescue StandardError
          attempt += 1
        end
      end
      false
    end
  end
end
