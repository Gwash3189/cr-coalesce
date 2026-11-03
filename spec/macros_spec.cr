require "./spec_helper"

class UserService
  include Coalesce

  getter hits = Atomic(Int32).new(0)
  getter misses = Atomic(Int32).new(0)
  getter calls = Atomic(Int32).new(0)

  coalesce key: ->(id : String) { "user:#{id}" },
    method: :fetch_user,
    ttl: 100.milliseconds,
    on_hit: :on_user_hit,
    on_miss: :on_user_miss

  def fetch_user(id : String) : String
    @calls.add(1)
    sleep 10.milliseconds
    "user_#{id}"
  end

  def on_user_hit(key : String)
    @hits.add(1)
  end

  def on_user_miss(key : String)
    @misses.add(1)
  end
end

class SymbolKeyService
  include Coalesce

  getter calls = Atomic(Int32).new(0)

  coalesce method: :process, key: :build_key

  def process(tenant : String, id : Int32) : String
    @calls.add(1)
    sleep 10.milliseconds
    "#{tenant}-#{id}"
  end

  def build_key(tenant : String, id : Int32) : String
    "custom:#{tenant}:#{id}"
  end
end

class DefaultKeyService
  include Coalesce

  getter calls = Atomic(Int32).new(0)

  coalesce :calculate

  def calculate(x : Int32, y : Int32 = 10) : Int32
    @calls.add(1)
    sleep 10.milliseconds
    x + y
  end
end

class FailureService
  include Coalesce

  getter attempts = Atomic(Int32).new(0)

  coalesce :flaky_operation, key: ->(id : String) { "flaky:#{id}" }

  def flaky_operation(id : String) : String
    attempt = @attempts.add(1)
    sleep 5.milliseconds
    if attempt == 0
      raise RuntimeError.new("temporary failure on #{id}")
    else
      "success_#{id}"
    end
  end
end

class ComplexArgsService
  include Coalesce

  getter calls = Atomic(Int32).new(0)

  coalesce :search, key: ->(query : String, tags : Array(String)) { "#{query}:#{tags.join(",")}" }

  def search(query : String, tags : Array(String), *, page : Int32 = 1, **options) : String
    @calls.add(1)
    "query=#{query},tags=#{tags.size},page=#{page},opt=#{options.size}"
  end
end

class ConstructedService
  include Coalesce

  getter prefix : String

  coalesce :greet, key: ->(name : String) { "greet:#{name}" }

  def initialize(@prefix : String)
  end

  def greet(name : String) : String
    "#{@prefix}, #{name}!"
  end
end

describe "Coalesce macro inclusion" do
  describe "instance method wrapping with proc key" do
    it "deduplicates concurrent calls sharing the same key" do
      service = UserService.new
      barrier = Channel(String).new(5)

      5.times do
        spawn do
          barrier.send(service.fetch_user("42"))
        end
      end

      results = Array.new(5) { barrier.receive }
      results.all? { |r| r == "user_42" }.should be_true
      service.calls.get.should eq(1)
      service.misses.get.should eq(1)
      service.hits.get.should eq(4)
    end

    it "separates calls with different keys" do
      service = UserService.new
      c1 = Channel(String).new(1)
      c2 = Channel(String).new(1)

      spawn { c1.send(service.fetch_user("A")) }
      spawn { c2.send(service.fetch_user("B")) }

      c1.receive.should eq("user_A")
      c2.receive.should eq("user_B")
      service.calls.get.should eq(2)
    end

    it "caches results within the configured TTL" do
      service = UserService.new
      first = service.fetch_user("99")
      second = service.fetch_user("99")

      first.should eq("user_99")
      second.should eq("user_99")
      service.calls.get.should eq(1)
    end
  end

  describe "instance method wrapping with symbol key" do
    it "invokes the key generator method" do
      service = SymbolKeyService.new
      barrier = Channel(String).new(3)

      3.times do
        spawn do
          barrier.send(service.process("acme", 101))
        end
      end

      results = Array.new(3) { barrier.receive }
      results.all? { |r| r == "acme-101" }.should be_true
      service.calls.get.should eq(1)
    end
  end

  describe "instance method wrapping with default key" do
    it "derives the key automatically from class, method, and arguments" do
      service = DefaultKeyService.new
      barrier = Channel(Int32).new(3)

      3.times do
        spawn do
          barrier.send(service.calculate(5))
        end
      end

      results = Array.new(3) { barrier.receive }
      results.all? { |r| r == 15 }.should be_true
      service.calls.get.should eq(1)
    end
  end

  describe "error propagation and non-caching of failures" do
    it "propagates error to all concurrent callers and allows subsequent retry" do
      service = FailureService.new
      err_channel = Channel(Exception).new(2)

      2.times do
        spawn do
          begin
            service.flaky_operation("target")
          rescue ex
            err_channel.send(ex)
          end
        end
      end

      errors = Array.new(2) { err_channel.receive }
      errors.size.should eq(2)
      errors.all? { |e| e.message == "temporary failure on target" }.should be_true

      recovered = service.flaky_operation("target")
      recovered.should eq("success_target")
    end
  end

  describe "complex method signatures" do
    it "preserves positional, named, and double-splat parameters" do
      service = ComplexArgsService.new
      res = service.search("crystal", ["fast", "typed"], page: 2, sort: "desc")
      res.should eq("query=crystal,tags=2,page=2,opt=1")
    end
  end

  describe "class constructor preservation" do
    it "preserves custom initialize with parameters on including class" do
      service = ConstructedService.new("Welcome")
      service.greet("Alice").should eq("Welcome, Alice!")
    end
  end
end
