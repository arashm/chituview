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
