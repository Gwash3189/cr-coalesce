require "./spec_helper"

private class TestCounter
  getter count = Atomic(Int32).new(0)

  def add(val : Int32)
    @count.add(val)
  end

  def get : Int32
    @count.get
  end
end

describe "Concurrency and Stampede Protection" do
  context "during a severe single-key cache stampede" do
    it "executes downstream work exactly once across 100 concurrent fibers" do
      downstream_hits = Atomic(Int32).new(0)
      total_fibers = 100
      channel = Channel(Int32).new(total_fibers)

      total_fibers.times do |i|
        spawn do
          result = Coalesce.coalesce("stampede:single") do
            downstream_hits.add(1)
            sleep 20.milliseconds
            999
          end
          channel.send(result)
        end
      end

      results = Array.new(total_fibers) { channel.receive }
      results.size.should eq(total_fibers)
      results.all? { |r| r == 999 }.should be_true
      downstream_hits.get.should eq(1)
    end
  end

  context "during a multi-key concurrent stampede" do
    it "executes downstream work exactly once per key across 150 concurrent fibers" do
      num_keys = 5
      fibers_per_key = 30
      total_fibers = num_keys * fibers_per_key

      counters = Array.new(num_keys) { TestCounter.new }
      channel = Channel(Tuple(String, String)).new(total_fibers)

      num_keys.times do |k_idx|
        target_key = "multi:stampede:#{k_idx}"
        fibers_per_key.times do
          spawn do
            res = Coalesce.coalesce(target_key) do
              counters[k_idx].add(1)
              sleep 15.milliseconds
              "res_#{target_key}"
            end
            channel.send({target_key, res})
          end
        end
      end

      results = Array.new(total_fibers) { channel.receive }
      results.size.should eq(total_fibers)

      num_keys.times do |k_idx|
        counters[k_idx].get.should eq(1)
      end
    end
  end
end
