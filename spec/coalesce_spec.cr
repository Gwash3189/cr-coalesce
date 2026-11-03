require "./spec_helper"

describe Coalesce do
  describe ".coalesce" do
    context "when executed with an invalid key" do
      it "raises a KeyError when key is empty" do
        expect_raises(Coalesce::KeyError) do
          Coalesce.coalesce("") { "value" }
        end
      end

      it "raises a KeyError when key contains only whitespace" do
        expect_raises(Coalesce::KeyError) do
          Coalesce.coalesce("   \t\n") { "value" }
        end
      end
    end

    context "when executed sequentially without TTL" do
      it "returns the result of the block" do
        result = Coalesce.coalesce("seq:1") { 42 }
        result.should eq(42)
      end

      it "executes the block on every sequential call" do
        count = 0
        Coalesce.coalesce("seq:2") { count += 1 }
        Coalesce.coalesce("seq:2") { count += 1 }
        count.should eq(2)
      end
    end

    context "when executed concurrently" do
      it "executes the block only once for the same key" do
        invocations = Atomic(Int32).new(0)
        barrier = Channel(Nil).new
        done = Channel(String).new(4)

        4.times do
          spawn do
            val = Coalesce.coalesce("concurrent:1") do
              invocations.add(1)
              barrier.receive
              "shared_result"
            end
            done.send(val)
          end
        end

        sleep 5.milliseconds
        barrier.send(nil)

        results = Array.new(4) { done.receive }
        invocations.get.should eq(1)
        results.all? { |r| r == "shared_result" }.should be_true
      end

      it "executes separate blocks for different keys" do
        invocations = Atomic(Int32).new(0)
        done = Channel(String).new(2)

        spawn do
          done.send(Coalesce.coalesce("key:A") { invocations.add(1); "A" })
        end
        spawn do
          done.send(Coalesce.coalesce("key:B") { invocations.add(1); "B" })
        end

        res = [done.receive, done.receive].sort
        res.should eq(["A", "B"])
        invocations.get.should eq(2)
      end
    end

    context "when the block raises an exception" do
      it "propagates the exception to all concurrent callers" do
        barrier = Channel(Nil).new
        errors = Channel(Exception).new(3)

        3.times do
          spawn do
            begin
              Coalesce.coalesce("error:1") do
                barrier.receive
                raise RuntimeError.new("downstream outage")
              end
            rescue ex
              errors.send(ex)
            end
          end
        end

        sleep 5.milliseconds
        barrier.send(nil)

        caught = Array.new(3) { errors.receive }
        caught.size.should eq(3)
        caught.all? { |e| e.message == "downstream outage" }.should be_true
      end

      it "evicts the key immediately so subsequent calls retry fresh work" do
        expect_raises(RuntimeError, "temporary failure") do
          Coalesce.coalesce("error:retry") { raise RuntimeError.new("temporary failure") }
        end

        retry_result = Coalesce.coalesce("error:retry") { "recovered" }
        retry_result.should eq("recovered")
      end
    end

    context "with ttl configured" do
      it "returns the cached value during the TTL duration" do
        executions = 0
        first = Coalesce.coalesce("ttl:test", ttl: 100.milliseconds) do
          executions += 1
          "cached_payload"
        end

        second = Coalesce.coalesce("ttl:test", ttl: 100.milliseconds) do
          executions += 1
          "fresh_payload"
        end

        first.should eq("cached_payload")
        second.should eq("cached_payload")
        executions.should eq(1)
      end

      it "re-executes work after the TTL expires" do
        executions = 0
        Coalesce.coalesce("ttl:expire", ttl: 20.milliseconds) do
          executions += 1
          "v1"
        end

        sleep 30.milliseconds

        second = Coalesce.coalesce("ttl:expire", ttl: 20.milliseconds) do
          executions += 1
          "v2"
        end

        second.should eq("v2")
        executions.should eq(2)
      end

      it "accepts numeric milliseconds as ttl" do
        executions = 0
        Coalesce.coalesce("ttl:num", ttl: 50) do
          executions += 1
          "num_ttl"
        end

        Coalesce.coalesce("ttl:num", ttl: 50) do
          executions += 1
          "new_val"
        end

        executions.should eq(1)
      end

      it "raises an ArgumentError when ttl is negative" do
        expect_raises(ArgumentError, /TTL must be non-negative/) do
          Coalesce.coalesce("ttl:neg", ttl: -10.milliseconds) { "neg" }
        end
      end
    end

    context "with callbacks" do
      it "invokes on_miss on initial execution and on_hit on concurrent joins" do
        miss_keys = [] of String
        hit_keys = [] of String
        barrier = Channel(Nil).new
        done = Channel(Nil).new(2)

        spawn do
          Coalesce.coalesce(
            "cb:key",
            on_miss: ->(k : String) { miss_keys << k; nil },
            on_hit: ->(k : String) { hit_keys << k; nil }
          ) do
            barrier.receive
            "done"
          end
          done.send(nil)
        end

        sleep 5.milliseconds

        spawn do
          Coalesce.coalesce(
            "cb:key",
            on_miss: ->(k : String) { miss_keys << k; nil },
            on_hit: ->(k : String) { hit_keys << k; nil }
          ) do
            "ignored"
          end
          done.send(nil)
        end

        sleep 5.milliseconds
        barrier.send(nil)
        done.receive
        done.receive

        miss_keys.should eq(["cb:key"])
        hit_keys.should eq(["cb:key"])
      end
    end

    context "with timeout" do
      it "raises a TimeoutError when waiting exceeds the configured timeout" do
        barrier = Channel(Nil).new
        timed_out = false

        spawn do
          Coalesce.coalesce("timeout:key") do
            barrier.receive
            "slow_result"
          end
        end

        sleep 5.milliseconds

        begin
          Coalesce.coalesce("timeout:key", timeout: 10.milliseconds) do
            "fallback"
          end
        rescue ex : Coalesce::TimeoutError
          timed_out = true
        end

        barrier.send(nil)
        timed_out.should be_true
      end
    end
  end

  describe ".singleflight" do
    it "functions as an alias for .coalesce" do
      result = Coalesce.singleflight("alias:1") { "from_alias" }
      result.should eq("from_alias")
    end
  end

  describe ".in_flight?" do
    it "returns true while work is executing and false once finished" do
      barrier = Channel(Nil).new
      done = Channel(Nil).new

      spawn do
        Coalesce.coalesce("flight:check") do
          barrier.receive
          "done"
        end
        done.send(nil)
      end

      sleep 5.milliseconds
      Coalesce.in_flight?("flight:check").should be_true

      barrier.send(nil)
      done.receive

      Coalesce.in_flight?("flight:check").should be_false
    end
  end

  describe ".cached?" do
    it "returns true while result is within TTL window" do
      Coalesce.coalesce("cached:check", ttl: 50.milliseconds) { "val" }
      Coalesce.cached?("cached:check").should be_true

      sleep 60.milliseconds
      Coalesce.cached?("cached:check").should be_false
    end
  end

  describe ".invalidate" do
    it "removes an entry from the registry" do
      Coalesce.coalesce("inv:key", ttl: 1.minute) { "val" }
      Coalesce.cached?("inv:key").should be_true

      removed = Coalesce.invalidate("inv:key")
      removed.should be_true
      Coalesce.cached?("inv:key").should be_false
    end

    it "returns false when the key does not exist" do
      Coalesce.invalidate("non_existent").should be_false
    end
  end

  describe ".reset" do
    it "clears all active and cached entries" do
      Coalesce.coalesce("r1", ttl: 1.minute) { 1 }
      Coalesce.coalesce("r2", ttl: 1.minute) { 2 }

      Coalesce.reset
      Coalesce.cached?("r1").should be_false
      Coalesce.cached?("r2").should be_false
    end
  end
end
