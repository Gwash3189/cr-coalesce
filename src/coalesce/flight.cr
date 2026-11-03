module Coalesce
  # Base flight interface allowing polymorphic storage in the central registry.
  abstract class AbstractFlight
    abstract def in_flight? : Bool
    abstract def cached? : Bool
    abstract def expired? : Bool
  end

  # Represents a single in-flight or cached execution for return type `T`.
  #
  # Manages synchronization between the worker fiber executing the downstream task
  # and any concurrent waiting fibers that arrive while the task is running.
  class Flight(T) < AbstractFlight
    @mutex = Mutex.new
    @completed = false
    @cached = false
    @has_value = false
    @result_value : T? = nil
    @error : Exception? = nil
    @expires_at : Time? = nil
    @waiters = [] of Channel(Nil)

    # Returns true if the operation is currently running and has not yet settled.
    def in_flight? : Bool
      @mutex.synchronize { !@completed }
    end

    # Returns true if this flight resolved successfully and is within its TTL window.
    def cached? : Bool
      @mutex.synchronize { @cached && !expired_internal? }
    end

    # Returns true if the flight had a TTL configured and that TTL has elapsed.
    def expired? : Bool
      @mutex.synchronize { expired_internal? }
    end

    private def expired_internal? : Bool
      if exp = @expires_at
        Time.utc >= exp
      else
        false
      end
    end

    # Returns the cached value directly if already completed successfully.
    def cached_value : T
      @mutex.synchronize do
        if err = @error
          raise err
        elsif @has_value
          {% if T == NoReturn %}
            raise @error || Error.new("Flight with NoReturn has no return value")
          {% else %}
            @result_value.as(T)
          {% end %}
        else
          raise Error.new("Flight has no cached value")
        end
      end
    end

    # Suspends the calling fiber until the in-flight operation completes, then
    # returns the result or raises the error produced by the worker fiber.
    def wait_result(key : String, timeout : Time::Span? = nil) : T
      waiter_ch = @mutex.synchronize do
        if @completed
          if err = @error
            raise err
          else
            {% if T == NoReturn %}
              raise Error.new("Flight with NoReturn settled unexpectedly")
            {% else %}
              return @result_value.as(T)
            {% end %}
          end
        end

        ch = Channel(Nil).new(1)
        @waiters << ch
        ch
      end

      if timeout
        select
        when waiter_ch.receive
        when ::timeout(timeout)
          settled_during_timeout = @mutex.synchronize do
            @waiters.delete(waiter_ch)
            @completed
          end

          unless settled_during_timeout
            raise TimeoutError.new(key, timeout)
          end
        end
      else
        waiter_ch.receive
      end

      @mutex.synchronize do
        if err = @error
          raise err
        else
          {% if T == NoReturn %}
            raise Error.new("Flight with NoReturn settled unexpectedly")
          {% else %}
            @result_value.as(T)
          {% end %}
        end
      end
    end

    # Completes the in-flight operation with a successful result and unblocks all waiting fibers.
    def complete(val : T) : Nil
      channels = @mutex.synchronize do
        @completed = true
        @has_value = true
        @result_value = val
        waiters = @waiters.dup
        @waiters.clear
        waiters
      end

      channels.each { |ch| ch.send(nil) }
    end

    # Fails the in-flight operation with an exception and unblocks all waiting fibers to re-raise it.
    def fail(err : Exception) : Nil
      channels = @mutex.synchronize do
        @completed = true
        @error = err
        waiters = @waiters.dup
        @waiters.clear
        waiters
      end

      channels.each { |ch| ch.send(nil) }
    end

    # Marks this completed flight as cached until `expires_at`.
    def mark_cached(expires_at : Time) : Nil
      @mutex.synchronize do
        @cached = true
        @expires_at = expires_at
      end
    end
  end
end
