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
