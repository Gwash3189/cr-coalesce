require "./spec_helper"

describe Coalesce::Builder do
  describe ".key and .for" do
    it "initializes a builder configured with the given key" do
      builder = Coalesce.key("user:10")
      builder.key_str.should eq("user:10")

      alias_builder = Coalesce.for("user:20")
      alias_builder.key_str.should eq("user:20")
    end

    it "raises a KeyError when key is empty" do
      expect_raises(Coalesce::KeyError) do
        Coalesce.key("")
      end
    end
  end

  describe "#ttl" do
    it "sets the TTL duration using Time::Span" do
      builder = Coalesce.key("b:ttl").ttl(5.seconds)
      builder.ttl_val.should eq(5.seconds)
    end

    it "sets the TTL duration using numeric milliseconds" do
      builder = Coalesce.key("b:ttl_num").ttl(2500)
      builder.ttl_val.should eq(2500.milliseconds)
    end
  end

  describe "#work and #run" do
    it "executes the block and returns the result" do
      result = Coalesce.key("b:work").ttl(1.second).work { "builder_result" }
      result.should eq("builder_result")
    end

    it "allows execution using .run alias" do
      result = Coalesce.key("b:run").run { 99 }
      result.should eq(99)
    end

    it "coalesces concurrent executions sharing the same key" do
      invocations = Atomic(Int32).new(0)
      barrier = Channel(Nil).new
      done = Channel(String).new(3)

      3.times do
        spawn do
          val = Coalesce.key("b:concurrent")
            .ttl(100.milliseconds)
            .work do
              invocations.add(1)
              barrier.receive
              "coalesced_val"
            end
          done.send(val)
        end
      end

      sleep 5.milliseconds
      barrier.send(nil)

      results = Array.new(3) { done.receive }
      invocations.get.should eq(1)
      results.all? { |r| r == "coalesced_val" }.should be_true
    end
  end

  describe "#on, #on_hit, and #on_miss" do
    it "invokes registered event handlers" do
      hit_fired = false
      miss_fired = false
      barrier = Channel(Nil).new
      done = Channel(Nil).new(2)

      spawn do
        Coalesce.key("b:events")
          .on_miss { miss_fired = true }
          .on_hit { hit_fired = true }
          .work do
            barrier.receive
            "ready"
          end
        done.send(nil)
      end

      sleep 5.milliseconds

      spawn do
        Coalesce.key("b:events")
          .on(:miss) { miss_fired = true }
          .on(:hit) { hit_fired = true }
          .work { "ignored" }
        done.send(nil)
      end

      sleep 5.milliseconds
      barrier.send(nil)
      done.receive
      done.receive

      miss_fired.should be_true
      hit_fired.should be_true
    end

    it "raises ArgumentError when .on receives an invalid event" do
      expect_raises(ArgumentError, /Unsupported Coalesce event/) do
        Coalesce.key("b:invalid_event").on(:unsupported) { }
      end
    end
  end

  describe "#in_flight?, #cached?, #invalidate, and #reset" do
    it "delegates registry inspection and mutation methods" do
      builder = Coalesce.key("b:mgmt").ttl(1.second)
      builder.cached?.should be_false

      builder.work { "saved" }
      builder.cached?.should be_true

      builder.invalidate.should be_true
      builder.cached?.should be_false

      builder.work { "saved_again" }
      builder.reset
      builder.cached?.should be_false
    end
  end
end
