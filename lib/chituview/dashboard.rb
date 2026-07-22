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
