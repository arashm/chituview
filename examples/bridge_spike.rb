# CONFIRMED 2026-07-22: tick-drain delivers background data; used by Dashboard.
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
