module Coalesce
  # A thread-safe coordinator for in-flight singleflight executions and TTL caching.
  class Registry
    def initialize
      @mutex = Mutex.new
      @entries = Hash(String, AbstractFlight).new
    end

    # Validates that a coalescing key is a non-empty, non-whitespace string.
    def self.validate_key!(key : String) : Nil
      if key.empty? || key.strip.empty?
        raise KeyError.new(key)
      end
    end

    # Normalizes and validates TTL duration. Accepts `Time::Span` or numeric milliseconds.
    def self.normalize_ttl(ttl : Time::Span | Number | Nil) : Time::Span?
      case ttl
      when Time::Span
        if ttl < Time::Span.zero
          raise ArgumentError.new("TTL must be non-negative, got: #{ttl}")
        end
        ttl
      when Number
        if ttl < 0
          raise ArgumentError.new("TTL must be non-negative, got: #{ttl}")
        end
        ttl.milliseconds
      else
        nil
      end
    end

    # Executes the given work block, coalescing concurrent calls sharing the same key.
    #
    # - If work for `key` is currently in flight, the calling fiber suspends and awaits
    #   the shared result without re-executing `block`.
    # - If a valid cached result exists within its `ttl` window, it is returned immediately.
    # - If `block` raises an exception, the error is propagated to all waiting fibers and
    #   evicted immediately so subsequent calls retry fresh work.
    def execute(
      key : String,
      ttl : Time::Span | Number | Nil = nil,
      timeout : Time::Span? = nil,
      on_hit : Proc(String, Nil)? = nil,
      on_miss : Proc(String, Nil)? = nil,
      &block : -> T
    ) : T forall T
      Registry.validate_key!(key)
      normalized_ttl = Registry.normalize_ttl(ttl)

      flight, is_first = @mutex.synchronize do
        if entry = @entries[key]?
          if entry.expired?
            @entries.delete(key)
            new_flight = Flight(T).new
            @entries[key] = new_flight
            {new_flight, true}
          else
            typed = entry.as?(Flight(T))
            if typed.nil?
              raise TypeMismatchError.new(key, T.to_s)
            end
            {typed, false}
          end
        else
          new_flight = Flight(T).new
          @entries[key] = new_flight
          {new_flight, true}
        end
      end

      if !is_first
        on_hit.try &.call(key)

        if flight.cached?
          return flight.cached_value
        else
          return flight.wait_result(key, timeout)
        end
      end

      on_miss.try &.call(key)

      begin
        result = yield

        @mutex.synchronize do
          if @entries[key]? == flight
            if normalized_ttl && normalized_ttl > Time::Span.zero
              flight.mark_cached(Time.utc + normalized_ttl)

              spawn do
                sleep normalized_ttl
                delete_if_expired(key, flight)
              end
            else
              @entries.delete(key)
            end
          end
        end

        flight.complete(result)
        result
      rescue ex : Exception
        @mutex.synchronize do
          if @entries[key]? == flight
            @entries.delete(key)
          end
        end

        flight.fail(ex)
        raise ex
      end
    end

    # Returns true if there is an active in-flight operation for `key`.
    def in_flight?(key : String) : Bool
      Registry.validate_key!(key)
      @mutex.synchronize do
        if entry = @entries[key]?
          entry.in_flight?
        else
          false
        end
      end
    end

    # Returns true if there is an unexpired cached value for `key`.
    def cached?(key : String) : Bool
      Registry.validate_key!(key)
      @mutex.synchronize do
        if entry = @entries[key]?
          entry.cached?
        else
          false
        end
      end
    end

    # Removes an in-flight or cached entry for `key`.
    # Returns true if an entry existed and was removed.
    def invalidate(key : String) : Bool
      Registry.validate_key!(key)
      @mutex.synchronize do
        !@entries.delete(key).nil?
      end
    end

    # Clears all in-flight and cached entries across all keys.
    def reset : Nil
      @mutex.synchronize do
        @entries.clear
      end
    end

    # Returns the number of currently tracked entries.
    def size : Int32
      @mutex.synchronize { @entries.size }
    end

    private def delete_if_expired(key : String, flight : AbstractFlight) : Nil
      @mutex.synchronize do
        if @entries[key]? == flight && flight.expired?
          @entries.delete(key)
        end
      end
    end
  end
end
