require "benchmark"
require "../src/cr-coalesce"

class BenchService
  include Coalesce

  coalesce key: ->(id : String) { "user:#{id}" }, method: :fetch, ttl: 1.second

  def fetch(id : String) : String
    "user_#{id}"
  end
end

service = BenchService.new
Coalesce.reset

Benchmark.bm do |x|
  x.report("sequential direct coalesce") do
    10_000.times do |i|
      Coalesce.coalesce("seq:#{i}") { i }
    end
  end

  x.report("concurrent singleflight stampede (100 fibers)") do
    100.times do
      channel = Channel(Int32).new(100)
      100.times do
        spawn do
          res = Coalesce.coalesce("stampede:bench") do
            42
          end
          channel.send(res)
        end
      end
      100.times { channel.receive }
    end
  end

  x.report("macro wrapped method (cached hit)") do
    10_000.times do
      service.fetch("42")
    end
  end
end
