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
