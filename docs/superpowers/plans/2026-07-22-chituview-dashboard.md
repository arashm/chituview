# chituview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a read-only live terminal dashboard (`chituview`) for Chitu-firmware resin printers that speak SDCP V3.0.0, showing live print status and opening the printer camera in an external viewer.

**Architecture:** Two layers. A pure protocol layer (Discovery over UDP, Protocol envelope builder, WebSocket Client with a reader thread feeding a thread-safe `inbox` Queue, and a `PrinterState` value object) with no UI and full unit tests. A TUI layer built on the charm-ruby Elm architecture (`bubbletea`/`lipgloss`/`bubbles`) where a `Dashboard` model polls the client inbox on a tick, folds status into `PrinterState`, and renders it.

**Tech Stack:** Ruby (>= 3.2), `bubbletea`, `lipgloss`, `bubbles`, `websocket`, minitest, rake. External runtime: `mpv`/`ffplay`/`vlc` for the camera.

## Global Constraints

- **Namespace:** everything under `Chituview`.
- **Read-only:** the only SDCP commands issued are `0` (status), `1` (attributes), `386` (camera enable/disable). Never issue print-control or file commands.
- **SDCP envelope (exact):** `{"Id", "Data": {"Cmd", "Data", "RequestID", "MainboardID", "TimeStamp", "From": 0}, "Topic": "sdcp/request/<MainboardID>"}` — JSON string keys exactly as shown.
- **Ports:** UDP `3000` discovery, WS `ws://<ip>:3030/websocket`, RTSP `rtsp://<ip>:554/video`.
- **Ruby floor:** `required_ruby_version >= 3.2`.
- **Runtime deps:** `bubbletea ~> 0.1`, `lipgloss ~> 0.2`, `bubbles ~> 0.1`, `websocket >= 1.0`. Dev deps: `minitest ~> 5.0`, `rake ~> 13.0`.
- **Charm API drift:** `bubbletea`/`lipgloss`/`bubbles` are young gems. The method names in this plan come from their current READMEs. When implementing the `view`/`update` (Tasks 6–8), if the installed gem version rejects a call, check the installed gem's README/source (`gem contents lipgloss`) and adjust the call while keeping the behavior. Tests assert on plain-text substrings precisely so styling-API drift never breaks them.
- **Ticks are milliseconds:** `CurrentTicks`/`TotalTicks` in SDCP status are milliseconds; divide by 1000 for seconds.
- **Fixtures are real:** `test/fixtures/*.json` are the actual payloads captured from the printer; do not fabricate replacements.

---

### Task 1: Gem scaffolding

**Files:**
- Create: `chituview.gemspec`
- Create: `Gemfile`
- Create: `Rakefile`
- Create: `lib/chituview.rb`
- Create: `lib/chituview/version.rb`
- Create: `test/test_helper.rb`
- Test: `test/version_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Chituview::VERSION` (String); `require "chituview"` loads the library; `rake test` runs minitest.

- [ ] **Step 1: Write the failing test**

`test/version_test.rb`:
```ruby
require "test_helper"

class VersionTest < Minitest::Test
  def test_version_is_a_semantic_string
    assert_match(/\A\d+\.\d+\.\d+\z/, Chituview::VERSION)
  end
end
```

`test/test_helper.rb`:
```ruby
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "chituview"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/version_test.rb`
Expected: FAIL — `cannot load such file -- chituview` (LoadError).

- [ ] **Step 3: Write minimal implementation**

`lib/chituview/version.rb`:
```ruby
module Chituview
  VERSION = "0.1.0"
end
```

`lib/chituview.rb`:
```ruby
require_relative "chituview/version"

module Chituview
  class Error < StandardError; end
end
```

`chituview.gemspec`:
```ruby
require_relative "lib/chituview/version"

Gem::Specification.new do |spec|
  spec.name        = "chituview"
  spec.version     = Chituview::VERSION
  spec.authors     = ["Arash Mousavi"]
  spec.email       = ["arash.mousavi@stewark.com"]
  spec.summary     = "Read-only live terminal dashboard for Chitu-firmware (SDCP) resin 3D printers."
  spec.description = "Discovers a Chitu/SDCP resin printer on the LAN and shows live print status " \
                     "(progress, layers, time, errors) in a terminal UI, with a keypress to open the camera."
  spec.homepage    = "https://github.com/arashmousavi/chituview"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files       = Dir["lib/**/*.rb", "bin/*", "README.md"]
  spec.bindir      = "bin"
  spec.executables = ["chituview"]
  spec.require_paths = ["lib"]

  spec.add_dependency "bubbletea", "~> 0.1"
  spec.add_dependency "lipgloss", "~> 0.2"
  spec.add_dependency "bubbles", "~> 0.1"
  spec.add_dependency "websocket", ">= 1.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
```

`Gemfile`:
```ruby
source "https://rubygems.org"
gemspec
```

`Rakefile`:
```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test
```

- [ ] **Step 4: Install deps and run the test**

Run: `bundle install && bundle exec rake test`
Expected: `bundle install` resolves (fetches bubbletea/lipgloss/bubbles/websocket); test suite PASSES (1 run, 1 assertion, 0 failures). If `bundle install` cannot fetch a charm gem's native build for this platform, stop and report — do not proceed.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: scaffold chituview gem"
```

---

### Task 2: Protocol (envelope builder, classify, command constants)

**Files:**
- Create: `lib/chituview/protocol.rb`
- Modify: `lib/chituview.rb` (add `require_relative "chituview/protocol"`)
- Test: `test/protocol_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Chituview::Protocol::CMD_STATUS = 0`, `CMD_ATTRIBUTES = 1`, `CMD_CAMERA = 386`
  - `Chituview::Protocol.request(cmd:, mainboard_id:, data: {}, id:, request_id:, timestamp:) -> Hash` (string-keyed SDCP envelope)
  - `Chituview::Protocol.classify(topic) -> :status | :attributes | :response | :error | :unknown`

- [ ] **Step 1: Write the failing test**

`test/protocol_test.rb`:
```ruby
require "test_helper"

class ProtocolTest < Minitest::Test
  def test_request_builds_exact_sdcp_envelope
    env = Chituview::Protocol.request(
      cmd: Chituview::Protocol::CMD_STATUS,
      mainboard_id: "82e29f99d60e0100",
      data: {},
      id: "aa", request_id: "bb", timestamp: 1784734565
    )

    assert_equal "aa", env["Id"]
    assert_equal "sdcp/request/82e29f99d60e0100", env["Topic"]
    assert_equal 0, env["Data"]["Cmd"]
    assert_equal({}, env["Data"]["Data"])
    assert_equal "bb", env["Data"]["RequestID"]
    assert_equal "82e29f99d60e0100", env["Data"]["MainboardID"]
    assert_equal 1784734565, env["Data"]["TimeStamp"]
    assert_equal 0, env["Data"]["From"]
  end

  def test_request_passes_command_data_through
    env = Chituview::Protocol.request(
      cmd: Chituview::Protocol::CMD_CAMERA, mainboard_id: "x",
      data: { "Enable" => 1 }, id: "i", request_id: "r", timestamp: 1
    )
    assert_equal 386, env["Data"]["Cmd"]
    assert_equal({ "Enable" => 1 }, env["Data"]["Data"])
  end

  def test_classify_maps_topics
    assert_equal :status,     Chituview::Protocol.classify("sdcp/status/abc")
    assert_equal :attributes, Chituview::Protocol.classify("sdcp/attributes/abc")
    assert_equal :response,   Chituview::Protocol.classify("sdcp/response/abc")
    assert_equal :error,      Chituview::Protocol.classify("sdcp/error/abc")
    assert_equal :unknown,    Chituview::Protocol.classify("sdcp/nope/abc")
    assert_equal :unknown,    Chituview::Protocol.classify(nil)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest -Ilib test/protocol_test.rb`
Expected: FAIL — `uninitialized constant Chituview::Protocol`.

- [ ] **Step 3: Write minimal implementation**

`lib/chituview/protocol.rb`:
```ruby
module Chituview
  module Protocol
    CMD_STATUS     = 0
    CMD_ATTRIBUTES = 1
    CMD_CAMERA     = 386

    TOPIC_TYPES = {
      "status"     => :status,
      "attributes" => :attributes,
      "response"   => :response,
      "error"      => :error
    }.freeze

    module_function

    def request(cmd:, mainboard_id:, id:, request_id:, timestamp:, data: {})
      {
        "Id" => id,
        "Data" => {
          "Cmd" => cmd,
          "Data" => data,
          "RequestID" => request_id,
          "MainboardID" => mainboard_id,
          "TimeStamp" => timestamp,
          "From" => 0
        },
        "Topic" => "sdcp/request/#{mainboard_id}"
      }
    end

    def classify(topic)
      return :unknown unless topic.is_a?(String)

      kind = topic.split("/")[1]
      TOPIC_TYPES.fetch(kind, :unknown)
    end
  end
end
```

Add to `lib/chituview.rb` after the version require:
```ruby
require_relative "chituview/protocol"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest -Ilib test/protocol_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/chituview.rb lib/chituview/protocol.rb test/protocol_test.rb
git commit -m "feat: SDCP protocol envelope builder and topic classifier"
```

---

### Task 3: PrinterState + real fixtures

**Files:**
- Create: `lib/chituview/printer_state.rb`
- Create: `test/fixtures/status_printing.json`
- Create: `test/fixtures/status_complete.json`
- Modify: `lib/chituview.rb` (add require)
- Test: `test/printer_state_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Chituview::PrinterState`
  - `.empty -> PrinterState` (no active print)
  - `.from_status(message_hash) -> PrinterState` where `message_hash` is a parsed `sdcp/status` frame
  - instance methods: `filename -> String`, `current_layer -> Integer`, `total_layer -> Integer`, `progress -> Float` (0.0–1.0), `print_status_code -> Integer`, `status_label -> String`, `error? -> Boolean`, `error_number -> Integer`, `elapsed_seconds -> Integer`, `remaining_seconds -> Integer`, `elapsed_human -> String`, `remaining_human -> String`, `printing? -> Boolean`, `active? -> Boolean`

- [ ] **Step 1: Write the fixtures and failing test**

`test/fixtures/status_printing.json`:
```json
{
  "Status": {
    "CurrentStatus": [1],
    "PrintInfo": {
      "Status": 2,
      "CurrentLayer": 1514,
      "TotalLayer": 1697,
      "CurrentTicks": 16852229,
      "TotalTicks": 18818950,
      "ErrorNumber": 0,
      "Filename": "bison - rays.ctb",
      "TaskId": "9baff5e4-85bb-11f1-b349-448763efe710"
    }
  },
  "MainboardID": "82e29f99d60e0100",
  "Topic": "sdcp/status/82e29f99d60e0100"
}
```

`test/fixtures/status_complete.json`:
```json
{
  "Status": {
    "CurrentStatus": [0],
    "PrintInfo": {
      "Status": 9,
      "CurrentLayer": 1697,
      "TotalLayer": 1697,
      "CurrentTicks": 18818950,
      "TotalTicks": 18818950,
      "ErrorNumber": 0,
      "Filename": "bison - rays.ctb",
      "TaskId": "9baff5e4-85bb-11f1-b349-448763efe710"
    }
  },
  "MainboardID": "82e29f99d60e0100",
  "Topic": "sdcp/status/82e29f99d60e0100"
}
```

`test/printer_state_test.rb`:
```ruby
require "test_helper"
require "json"

class PrinterStateTest < Minitest::Test
  def fixture(name)
    JSON.parse(File.read(File.expand_path("fixtures/#{name}.json", __dir__)))
  end

  def printing
    Chituview::PrinterState.from_status(fixture("status_printing"))
  end

  def test_parses_core_fields
    s = printing
    assert_equal "bison - rays.ctb", s.filename
    assert_equal 1514, s.current_layer
    assert_equal 1697, s.total_layer
    assert_equal 0, s.error_number
    refute s.error?
    assert s.active?
    assert s.printing?
  end

  def test_progress_is_layer_ratio
    assert_in_delta 1514.0 / 1697.0, printing.progress, 0.0001
  end

  def test_time_from_ticks_in_milliseconds
    s = printing
    assert_equal 16852, s.elapsed_seconds
    assert_equal (18818950 - 16852229) / 1000, s.remaining_seconds
    assert_equal "4h 40m", s.elapsed_human
    assert_equal "32m", s.remaining_human
  end

  def test_status_label_printing
    assert_equal "printing", printing.status_label
  end

  def test_complete_fixture
    s = Chituview::PrinterState.from_status(fixture("status_complete"))
    assert_equal "complete", s.status_label
    assert_in_delta 1.0, s.progress, 0.0001
    refute s.printing?
  end

  def test_error_state
    raw = fixture("status_printing")
    raw["Status"]["PrintInfo"]["ErrorNumber"] = 5
    s = Chituview::PrinterState.from_status(raw)
    assert s.error?
    assert_equal 5, s.error_number
    assert_equal "error", s.status_label
  end

  def test_empty_state_is_idle_and_safe
    s = Chituview::PrinterState.empty
    refute s.active?
    assert_equal "idle", s.status_label
    assert_equal 0.0, s.progress
    assert_equal "", s.filename
    assert_equal "0m", s.elapsed_human
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest -Ilib test/printer_state_test.rb`
Expected: FAIL — `uninitialized constant Chituview::PrinterState`.

- [ ] **Step 3: Write minimal implementation**

`lib/chituview/printer_state.rb`:
```ruby
module Chituview
  class PrinterState
    def self.empty
      new({})
    end

    def self.from_status(message_hash)
      info = message_hash.dig("Status", "PrintInfo") || {}
      new(info)
    end

    def initialize(print_info)
      @info = print_info || {}
    end

    def filename       = @info.fetch("Filename", "").to_s
    def current_layer  = @info.fetch("CurrentLayer", 0).to_i
    def total_layer    = @info.fetch("TotalLayer", 0).to_i
    def print_status_code = @info.fetch("Status", -1).to_i
    def error_number   = @info.fetch("ErrorNumber", 0).to_i
    def error?         = error_number != 0

    # There IS an active task when the payload carries layer totals.
    def active? = total_layer.positive?

    def progress
      return 0.0 unless total_layer.positive?

      current_layer.to_f / total_layer
    end

    def printing?
      active? && !error? && current_layer < total_layer
    end

    def status_label
      return "idle"     unless active?
      return "error"    if error?
      return "complete" if current_layer >= total_layer

      "printing"
    end

    def elapsed_seconds   = (@info.fetch("CurrentTicks", 0).to_i / 1000)
    def remaining_seconds = ([@info.fetch("TotalTicks", 0).to_i - @info.fetch("CurrentTicks", 0).to_i, 0].max / 1000)
    def elapsed_human     = self.class.human_duration(elapsed_seconds)
    def remaining_human   = self.class.human_duration(remaining_seconds)

    def self.human_duration(seconds)
      seconds = seconds.to_i
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      hours.positive? ? "#{hours}h #{minutes}m" : "#{minutes}m"
    end
  end
end
```

Add to `lib/chituview.rb`:
```ruby
require_relative "chituview/printer_state"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest -Ilib test/printer_state_test.rb`
Expected: PASS (7 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/chituview.rb lib/chituview/printer_state.rb test/printer_state_test.rb test/fixtures/
git commit -m "feat: PrinterState value object with real captured fixtures"
```

---

### Task 4: Discovery (UDP)

**Files:**
- Create: `lib/chituview/discovery.rb`
- Modify: `lib/chituview.rb` (add require)
- Test: `test/discovery_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Chituview::Discovery::PrinterInfo = Struct.new(:name, :ip, :mainboard_id, :machine_name, :brand, :firmware, :protocol, keyword_init: true)`
  - `Chituview::Discovery.parse_reply(json_string, ip) -> PrinterInfo | nil`
  - `Chituview::Discovery.discover(timeout: 3, socket: nil, broadcast: "255.255.255.255") -> [PrinterInfo]`
  - `Chituview::Discovery.probe(ip, timeout: 2, socket: nil) -> PrinterInfo | nil`

- [ ] **Step 1: Write the failing test**

`test/discovery_test.rb`:
```ruby
require "test_helper"

class DiscoveryTest < Minitest::Test
  REPLY = <<~JSON
    {"Id":"x","Data":{"Name":"3D Printer","MachineName":"GK3 GK3Pro",
    "BrandName":"UniFormation","MainboardIP":"192.168.50.133",
    "MainboardID":"82e29f99d60e0100","ProtocolVersion":"V3.0.0",
    "FirmwareVersion":"V1.4.9"}}
  JSON

  def test_parse_reply_extracts_printer_info
    info = Chituview::Discovery.parse_reply(REPLY, "192.168.50.133")
    assert_equal "192.168.50.133", info.ip
    assert_equal "82e29f99d60e0100", info.mainboard_id
    assert_equal "GK3 GK3Pro", info.machine_name
    assert_equal "UniFormation", info.brand
    assert_equal "V1.4.9", info.firmware
    assert_equal "V3.0.0", info.protocol
  end

  def test_parse_reply_returns_nil_on_garbage
    assert_nil Chituview::Discovery.parse_reply("not json", "1.2.3.4")
    assert_nil Chituview::Discovery.parse_reply("{}", "1.2.3.4")
  end

  # Fake UDP socket: records the probe, then yields one reply then timeouts.
  class FakeSocket
    attr_reader :sent
    def initialize(reply, from_ip)
      @reply = reply
      @from_ip = from_ip
      @sent = []
      @served = false
    end
    def setsockopt(*) = nil
    def send(payload, _flags, *_addr) = @sent << payload
    def recvfrom(_len)
      raise IO::TimeoutError if @served

      @served = true
      [@reply, ["AF_INET", 3000, @from_ip, @from_ip]]
    end
    def close = nil
  end

  def test_discover_collects_replies_until_timeout
    sock = FakeSocket.new(REPLY, "192.168.50.133")
    printers = Chituview::Discovery.discover(timeout: 0.2, socket: sock)
    assert_equal 1, printers.size
    assert_equal "82e29f99d60e0100", printers.first.mainboard_id
    assert_equal ["M99999"], sock.sent
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest -Ilib test/discovery_test.rb`
Expected: FAIL — `uninitialized constant Chituview::Discovery`.

- [ ] **Step 3: Write minimal implementation**

`lib/chituview/discovery.rb`:
```ruby
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
```

Add to `lib/chituview.rb`:
```ruby
require_relative "chituview/discovery"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest -Ilib test/discovery_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/chituview.rb lib/chituview/discovery.rb test/discovery_test.rb
git commit -m "feat: UDP SDCP discovery"
```

---

### Task 5: Client (WebSocket over TCP)

**Files:**
- Create: `lib/chituview/client.rb`
- Modify: `lib/chituview.rb` (add require)
- Test: `test/client_test.rb`

**Interfaces:**
- Consumes: `Chituview::Protocol`.
- Produces: `Chituview::Client`
  - `.new(ip:, mainboard_id:, port: 3030, socket_factory: nil, max_backoff: 8.0)` — `socket_factory` is a callable returning an object responding to `write`, `readpartial(n)`, `close`.
  - `#connect -> self` (TCP connect + WS handshake, starts reader thread)
  - `#request(cmd, data = {}) -> void` (sends a WS text frame with the SDCP envelope)
  - `#inbox -> Queue` of `{ type: Symbol, payload: Hash }` (type from `Protocol.classify`; also emits `:closed` when the link drops)
  - `#feed(bytes) -> void` (internal: parse incoming WS frames, push classified messages) — public for testing
  - `#backoff_delay(attempt) -> Float` (capped exponential: `min(0.5 * 2**attempt, max_backoff)`) — public for testing
  - `#connected? -> Boolean`, `#close -> void`

Frame serialization/parsing and the backoff schedule are tested directly via
`#feed`, `#request`, and `#backoff_delay` (with a recording fake socket), so no
real handshake/threads are needed in unit tests. **Auto-reconnect** lives in the
reader thread: on a read error it emits `:closed`, then re-establishes the
connection with capped exponential backoff (`backoff_delay`) and re-requests
status, so the last state stays on screen until a fresh status arrives. The live
handshake + reconnect paths are exercised by the Task 10 smoke test.

- [ ] **Step 1: Write the failing test**

`test/client_test.rb`:
```ruby
require "test_helper"
require "websocket"
require "json"

class ClientTest < Minitest::Test
  # Records writes; never used for reading in these unit tests.
  class RecordingSocket
    attr_reader :written
    def initialize = @written = +"".b
    def write(bytes) = @written << bytes
    def readpartial(_n) = raise IOError, "not used"
    def close = nil
  end

  def client
    sock = RecordingSocket.new
    c = Chituview::Client.new(
      ip: "1.2.3.4", mainboard_id: "MB",
      socket_factory: -> { sock }
    )
    # Inject the socket without doing a real handshake.
    c.instance_variable_set(:@socket, sock)
    c.instance_variable_set(:@ws_version, 13)
    [c, sock]
  end

  def test_request_writes_a_websocket_text_frame_with_the_envelope
    c, sock = client
    c.request(Chituview::Protocol::CMD_CAMERA, { "Enable" => 1 })

    # Decode what was written back into a message using the websocket gem.
    incoming = WebSocket::Frame::Incoming::Server.new(version: 13)
    incoming << sock.written
    frame = incoming.next
    refute_nil frame, "expected a decodable websocket frame"

    env = JSON.parse(frame.data)
    assert_equal 386, env["Data"]["Cmd"]
    assert_equal({ "Enable" => 1 }, env["Data"]["Data"])
    assert_equal "sdcp/request/MB", env["Topic"]
    assert_equal "MB", env["Data"]["MainboardID"]
  end

  def test_feed_parses_status_frames_into_inbox
    c, = client
    status = {
      "Status" => { "PrintInfo" => { "Filename" => "a.ctb" } },
      "Topic" => "sdcp/status/MB"
    }
    # Build a server->client text frame the way the printer would.
    out = WebSocket::Frame::Outgoing::Server.new(
      version: 13, data: JSON.generate(status), type: :text
    )
    c.feed(out.to_s)

    msg = c.inbox.pop
    assert_equal :status, msg[:type]
    assert_equal "a.ctb", msg[:payload].dig("Status", "PrintInfo", "Filename")
  end

  def test_feed_ignores_non_json_frames
    c, = client
    out = WebSocket::Frame::Outgoing::Server.new(version: 13, data: "garbage", type: :text)
    c.feed(out.to_s)
    assert c.inbox.empty?
  end

  def test_backoff_is_capped_exponential
    c, = client
    assert_in_delta 0.5, c.backoff_delay(0), 0.0001
    assert_in_delta 1.0, c.backoff_delay(1), 0.0001
    assert_in_delta 2.0, c.backoff_delay(2), 0.0001
    # capped at max_backoff (default 8.0)
    assert_in_delta 8.0, c.backoff_delay(10), 0.0001
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest -Ilib test/client_test.rb`
Expected: FAIL — `uninitialized constant Chituview::Client`.

- [ ] **Step 3: Write minimal implementation**

`lib/chituview/client.rb`:
```ruby
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
```

Add to `lib/chituview.rb`:
```ruby
require_relative "chituview/client"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest -Ilib test/client_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/chituview.rb lib/chituview/client.rb test/client_test.rb
git commit -m "feat: SDCP WebSocket client with inbox queue and auto-reconnect"
```

---

### Task 6: Async-bridge spike (investigative — confirms the poll pattern)

**Files:**
- Create: `examples/bridge_spike.rb`

**Interfaces:**
- Consumes: `bubbletea` gem, a `Queue`.
- Produces: a confirmed pattern for delivering background-thread data into the
  bubbletea loop. Ships nothing into `lib/`; the confirmed pattern is used in Task 8.

This is a spike, not TDD. Its verification is a manual run and an observation.

- [ ] **Step 1: Write the spike program**

`examples/bridge_spike.rb`:
```ruby
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "bubbletea"

# A background thread pushes ticks onto a queue; the model polls the queue on a
# bubbletea tick and renders the latest value. This is the "tick-drain" bridge.
class SpikeMessage < Bubbletea::Message; end
class PollMessage < Bubbletea::Message; end

class Spike
  include Bubbletea::Model

  def initialize(queue)
    @queue = queue
    @value = 0
    @count = 0
  end

  def init = [self, Bubbletea.tick(0.1) { PollMessage.new }]

  def update(message)
    case message
    when PollMessage
      drain
      return [self, Bubbletea.quit] if @count >= 20

      [self, Bubbletea.tick(0.1) { PollMessage.new }]
    when Bubbletea::KeyMessage
      message.to_s == "q" ? [self, Bubbletea.quit] : [self, nil]
    else
      [self, nil]
    end
  end

  def view = "background value: #{@value}   (polls: #{@count})\npress q to quit"

  private

  def drain
    @count += 1
    loop { @value = @queue.pop(true) }
  rescue ThreadError
    # queue empty — expected
  end
end

queue = Queue.new
producer = Thread.new do
  i = 0
  loop do
    sleep 0.25
    queue << (i += 1)
  end
end

Bubbletea.run(Spike.new(queue))
producer.kill
```

- [ ] **Step 2: Run the spike and observe**

Run: `bundle exec ruby examples/bridge_spike.rb`
Expected observation: the "background value" number climbs on screen without any
keypress (proving background-thread data reaches the render loop via the
tick-drain), and `q` quits. If it renders and updates, the tick-drain bridge is
confirmed — proceed to Task 8 using it.

- [ ] **Step 3: Record the outcome**

Append a one-line comment at the top of `examples/bridge_spike.rb` stating the
result, e.g. `# CONFIRMED 2026-07-22: tick-drain delivers background data; used by Dashboard.`
If (unexpectedly) `Bubbletea.tick` does not fire repeatedly, note it and fall back
to re-issuing via `Bubbletea.send_message` in a tight loop; the Dashboard update
logic in Task 8 is otherwise unchanged.

- [ ] **Step 4: Commit**

```bash
git add examples/bridge_spike.rb
git commit -m "spike: confirm bubbletea tick-drain async bridge"
```

---

### Task 7: Camera

**Files:**
- Create: `lib/chituview/camera.rb`
- Modify: `lib/chituview.rb` (add require)
- Test: `test/camera_test.rb`

**Interfaces:**
- Consumes: `Chituview::Protocol`, a client responding to `#request(cmd, data)`.
- Produces: `Chituview::Camera`
  - `.new(players: %w[mpv ffplay vlc], which: nil, spawn: nil)` — `which` is a callable `(String) -> Boolean` (is the player installed?); `spawn` is a callable `(String, String) -> Object` receiving `(player, url)`.
  - `#open(client, ip) -> String` — sends `CMD_CAMERA {"Enable"=>1}`, spawns the first available player on `rtsp://<ip>:554/video`, returns a human status string.
  - `#disable(client) -> void` — best-effort `CMD_CAMERA {"Enable"=>0}`.
  - `VIDEO_URL_TEMPLATE` — `"rtsp://%s:554/video"`.

- [ ] **Step 1: Write the failing test**

`test/camera_test.rb`:
```ruby
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest -Ilib test/camera_test.rb`
Expected: FAIL — `uninitialized constant Chituview::Camera`.

- [ ] **Step 3: Write minimal implementation**

`lib/chituview/camera.rb`:
```ruby
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
```

Add to `lib/chituview.rb`:
```ruby
require_relative "chituview/camera"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest -Ilib test/camera_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/chituview.rb lib/chituview/camera.rb test/camera_test.rb
git commit -m "feat: camera enable + external viewer spawn"
```

---

### Task 8: Dashboard (bubbletea Model)

**Files:**
- Create: `lib/chituview/dashboard.rb`
- Modify: `lib/chituview.rb` (add require)
- Test: `test/dashboard_test.rb`

**Interfaces:**
- Consumes: `Chituview::PrinterState`, `Chituview::Camera`, `Chituview::Protocol`, a client exposing `#inbox` (Queue), `#request`, `#close`, `#connected?`; `bubbletea`, `lipgloss`, `bubbles`.
- Produces: `Chituview::Dashboard`
  - `.new(client:, camera:, ip:, machine_name: "printer", printer: PrinterState.empty)`
  - includes `Bubbletea::Model`; implements `init`, `update(message)`, `view`
  - testable helpers: `#handle_poll -> [self, cmd]`, `#handle_key(str) -> [self, cmd]`, `#quitting? -> Boolean`, `#connection -> Symbol`, `#status_note -> String`
  - `POLL_INTERVAL = 0.15`

- [ ] **Step 1: Write the failing test**

`test/dashboard_test.rb`:
```ruby
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest -Ilib test/dashboard_test.rb`
Expected: FAIL — `uninitialized constant Chituview::Dashboard`.

- [ ] **Step 3: Write minimal implementation**

`lib/chituview/dashboard.rb`:
```ruby
require "bubbletea"
require "lipgloss"
require "bubbles"

module Chituview
  class PollMessage < Bubbletea::Message; end

  class Dashboard
    include Bubbletea::Model

    POLL_INTERVAL = 0.15

    attr_reader :connection, :status_note

    def initialize(client:, camera:, ip:, machine_name: "printer", printer: PrinterState.empty)
      @client = client
      @camera = camera
      @ip = ip
      @machine_name = machine_name
      @state = printer
      @connection = :connecting
      @status_note = ""
      @quitting = false
      @progress = Bubbles::Progress.new(width: 30)
    end

    def quitting? = @quitting

    def init
      [self, Bubbletea.tick(POLL_INTERVAL) { PollMessage.new }]
    end

    def update(message)
      case message
      when PollMessage          then handle_poll
      when Bubbletea::KeyMessage then handle_key(message.to_s)
      else [self, nil]
      end
    end

    def handle_poll
      drain_inbox
      [self, Bubbletea.tick(POLL_INTERVAL) { PollMessage.new }]
    end

    def handle_key(key)
      case key
      when "q", "ctrl+c"
        @quitting = true
        @camera.disable(@client)
        @client.close
        [self, Bubbletea.quit]
      when "c"
        @status_note = @camera.open(@client, @ip)
        [self, nil]
      when "r"
        @connection = :connecting
        @status_note = "reconnect requested"
        [self, nil]
      else
        [self, nil]
      end
    end

    def view
      border_color = { live: "10", reconnecting: "11", connecting: "11", error: "9" }
                     .fetch(@connection, "8")
      @progress.set_percent(@state.progress)

      body = [
        title_line,
        @state.filename.empty? ? "(no active print)" : @state.filename,
        "#{@progress.view}  layer #{@state.current_layer}/#{@state.total_layer}",
        "status: #{@state.status_label}    error: #{@state.error? ? @state.error_number : "none"}",
        "elapsed #{@state.elapsed_human}    remaining ~#{@state.remaining_human}",
        "",
        footer_line
      ].join("\n")

      Lipgloss::Style.new
                     .border(:rounded)
                     .border_foreground(border_color)
                     .padding(0, 1)
                     .render(body)
    end

    private

    def title_line
      dot = { live: "● live", reconnecting: "◌ reconnecting…", connecting: "◌ connecting…", error: "✖ error" }
            .fetch(@connection, "?")
      "#{@machine_name} · #{@ip}   #{dot}"
    end

    def footer_line
      note = @status_note.empty? ? "" : "   #{@status_note}"
      "read-only · [c]amera  [r]econnect  [q]uit#{note}"
    end

    def drain_inbox
      handled = false
      loop do
        msg = @client.inbox.pop(true)
        handled = true
        apply(msg)
      end
    rescue ThreadError
      # inbox empty
      @connection = :live if handled && @connection == :connecting
    end

    def apply(msg)
      case msg[:type]
      when :status
        @state = PrinterState.from_status(msg[:payload])
        @connection = :live
      when :closed
        @connection = :reconnecting
      when :error
        @connection = :error
      end
    end
  end
end
```

Add to `lib/chituview.rb`:
```ruby
require_relative "chituview/dashboard"
```

> Charm API drift check (per Global Constraints): if `Lipgloss::Style#border`,
> `#border_foreground`, `#padding`, or `Bubbles::Progress#set_percent`/`#view`
> raise on the installed version, run `gem contents lipgloss` / `gem contents bubbles`,
> read the source, and adjust the calls. The tests assert only on the plain-text
> content (filename, `1514/1697`, `printing`, `idle`), which survives any styling
> change, so a green suite confirms the fix.

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest -Ilib test/dashboard_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/chituview.rb lib/chituview/dashboard.rb test/dashboard_test.rb
git commit -m "feat: bubbletea dashboard model with poll-drain bridge"
```

---

### Task 9: CLI + executable

**Files:**
- Create: `lib/chituview/cli.rb`
- Create: `bin/chituview`
- Modify: `lib/chituview.rb` (add require)
- Test: `test/cli_test.rb`

**Interfaces:**
- Consumes: `Chituview::Discovery`, `Chituview::Client`, `Chituview::Camera`, `Chituview::Dashboard`.
- Produces: `Chituview::CLI`
  - `Chituview::CLI::Options = Struct.new(:ip, :discover, :timeout, :help, :version, keyword_init: true)`
  - `.parse(argv) -> Options`
  - `#initialize(argv)`, `#run -> Integer` (process exit code)

- [ ] **Step 1: Write the failing test**

`test/cli_test.rb`:
```ruby
require "test_helper"

class CliTest < Minitest::Test
  def test_parse_positional_ip
    opts = Chituview::CLI.parse(["192.168.50.133"])
    assert_equal "192.168.50.133", opts.ip
    refute opts.discover
  end

  def test_parse_discover_flag
    opts = Chituview::CLI.parse(["--discover"])
    assert opts.discover
    assert_nil opts.ip
  end

  def test_parse_timeout
    opts = Chituview::CLI.parse(["--timeout", "5", "10.0.0.2"])
    assert_equal 5.0, opts.timeout
    assert_equal "10.0.0.2", opts.ip
  end

  def test_parse_help_and_version
    assert Chituview::CLI.parse(["--help"]).help
    assert Chituview::CLI.parse(["--version"]).version
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest -Ilib test/cli_test.rb`
Expected: FAIL — `uninitialized constant Chituview::CLI`.

- [ ] **Step 3: Write minimal implementation**

`lib/chituview/cli.rb`:
```ruby
require "optparse"

module Chituview
  class CLI
    Options = Struct.new(:ip, :discover, :timeout, :help, :version, keyword_init: true)

    def self.parse(argv)
      opts = Options.new(ip: nil, discover: false, timeout: 3.0, help: false, version: false)
      parser = OptionParser.new do |o|
        o.banner = "Usage: chituview [IP] [options]"
        o.on("--discover", "List printers found on the LAN and exit") { opts.discover = true }
        o.on("--timeout SECONDS", Float, "Discovery timeout (default 3)") { |v| opts.timeout = v }
        o.on("-h", "--help", "Show help") { opts.help = true }
        o.on("-v", "--version", "Show version") { opts.version = true }
      end
      rest = parser.parse(argv)
      opts.ip = rest.first
      @parser = parser
      opts
    end

    def self.parser = @parser

    def initialize(argv)
      @argv = argv
    end

    def run
      opts = self.class.parse(@argv)
      return puts_and_zero(self.class.parser.to_s) if opts.help
      return puts_and_zero("chituview #{VERSION}") if opts.version
      return run_discover(opts) if opts.discover

      printer = resolve_printer(opts)
      return 1 unless printer

      launch(printer)
    rescue OptionParser::ParseError => e
      warn e.message
      1
    end

    private

    def puts_and_zero(text)
      puts text
      0
    end

    def run_discover(opts)
      printers = Discovery.discover(timeout: opts.timeout)
      if printers.empty?
        warn "No SDCP printers found. Pass an IP explicitly: chituview <ip>"
        return 1
      end
      printers.each { |p| puts "#{p.ip}\t#{p.brand} #{p.machine_name}\t#{p.mainboard_id}" }
      0
    end

    def resolve_printer(opts)
      if opts.ip
        info = Discovery.probe(opts.ip, timeout: opts.timeout)
        return info if info

        warn "No SDCP printer responded at #{opts.ip}."
        return nil
      end

      printers = Discovery.discover(timeout: opts.timeout)
      case printers.size
      when 0
        warn "No SDCP printers found. Pass an IP explicitly: chituview <ip>"
        nil
      when 1
        printers.first
      else
        warn "Multiple printers found; pass one explicitly:"
        printers.each { |p| warn "  #{p.ip}  #{p.machine_name}" }
        nil
      end
    end

    def launch(printer)
      client = Client.new(ip: printer.ip, mainboard_id: printer.mainboard_id)
      begin
        client.connect
      rescue Chituview::Error, SocketError, SystemCallError => e
        warn "Could not connect to #{printer.ip}:3030 — #{e.message}"
        return 1
      end
      client.request(Protocol::CMD_STATUS)
      client.request(Protocol::CMD_ATTRIBUTES)
      dashboard = Dashboard.new(
        client: client, camera: Camera.new, ip: printer.ip,
        machine_name: "#{printer.brand} #{printer.machine_name}".strip
      )
      Bubbletea.run(dashboard, alt_screen: true)
      0
    ensure
      client&.close
    end
  end
end
```

`bin/chituview`:
```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/chituview"

exit(Chituview::CLI.new(ARGV).run)
```

Add to `lib/chituview.rb`:
```ruby
require_relative "chituview/cli"
```

- [ ] **Step 4: Make the binary executable and run tests**

Run: `chmod +x bin/chituview && ruby -Itest -Ilib test/cli_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rake test`
Expected: all tests PASS (0 failures, 0 errors).

- [ ] **Step 6: Commit**

```bash
git add lib/chituview.rb lib/chituview/cli.rb bin/chituview test/cli_test.rb
git commit -m "feat: CLI, discovery wiring, and chituview executable"
```

---

### Task 10: README + live smoke test

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything.
- Produces: user-facing docs + a verified end-to-end run against the real printer.

- [ ] **Step 1: Write the README**

`README.md`:
```markdown
# chituview

A read-only live terminal dashboard for Chitu-firmware resin 3D printers that
speak **SDCP V3.0.0** on the local network (UniFormation, Elegoo, and other
Chitu-based machines).

It discovers the printer over UDP, opens a WebSocket to stream live status, and
renders progress, layer counts, elapsed/remaining time, and error state in a
terminal UI. Press `c` to open the printer camera in an external player.

## Install

```bash
bundle install
gem build chituview.gemspec && gem install chituview-*.gem   # optional
```

## Usage

```bash
chituview                    # auto-discover on the LAN
chituview 192.168.50.133     # connect to a known IP
chituview --discover         # list printers and exit
chituview --timeout 5        # discovery timeout (seconds)
```

Keys: `c` open camera · `r` reconnect · `q` quit.

Camera requires one of `mpv`, `ffplay`, or `vlc` on your PATH.

## What it does not do

Read-only by design: it never pauses, resumes, stops, or deletes prints or files.
It only queries status/attributes and toggles the camera.

## How it works

See `docs/superpowers/specs/2026-07-22-chituview-dashboard-design.md` for the SDCP
protocol details it relies on.

## License

MIT
```

- [ ] **Step 2: Run the live smoke test against the printer**

Run: `bundle exec bin/chituview 192.168.50.133`
Expected observation:
- The dashboard appears with a rounded border and green `● live` indicator.
- It shows the current filename and a progress bar with `layer N/1697` updating
  every few seconds.
- Pressing `c` launches mpv on the camera; the footer shows `camera opened in mpv`.
- Pressing `q` exits cleanly and restores the terminal.
- Reconnect check (optional): briefly drop the printer from the network (or toggle
  its wifi). The border turns yellow (`◌ reconnecting…`) while the last-known state
  stays visible, then returns to green `● live` once the printer is back — proving
  the Client's auto-reconnect path.

If the border/styling raises an error at launch, apply the Charm API drift check
from Task 8 (read the installed gem source, adjust the styling calls), then re-run.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README"
```

- [ ] **Step 4: (Optional) tag the working version**

```bash
git tag v0.1.0
```

---

## Notes for the implementer

- Run each task's test file directly (`ruby -Itest -Ilib test/<file>`) for a fast
  loop; run `bundle exec rake test` before committing Task 9 and Task 10.
- The only tasks that touch the real printer are the Task 6 spike (needs only
  bubbletea) and the Task 10 smoke test (needs the printer at its IP). Everything
  else is hermetic with fakes/fixtures.
- If `bundle install` cannot install a charm gem on this platform, stop and report
  — the whole UI layer depends on them and there is no pure-Ruby fallback in scope.
```
