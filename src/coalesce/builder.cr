module Coalesce
  # Fluent builder for configuring and executing coalesced operations.
  #
  # ```
  # user = Coalesce.key("user:42")
  #   .ttl(2.seconds)
  #   .on_hit { |key| Log.info { "Shared in-flight or cached result for #{key}" } }
  #   .on_miss { |key| Log.info { "Executing fresh work for #{key}" } }
  #   .work { database.find_user(42) }
  # ```
  class Builder
    getter key_str : String
    getter ttl_val : Time::Span?
    getter timeout_val : Time::Span?
    getter hit_handlers : Array(Proc(String, Nil))
    getter miss_handlers : Array(Proc(String, Nil))
    getter registry : Registry

    def initialize(
      @key_str : String = "",
      @ttl_val : Time::Span? = nil,
      @timeout_val : Time::Span? = nil,
      @hit_handlers : Array(Proc(String, Nil)) = [] of Proc(String, Nil),
      @miss_handlers : Array(Proc(String, Nil)) = [] of Proc(String, Nil),
      @registry : Registry = Coalesce.default_registry,
    )
    end

    # Sets the coalescing key.
    def key(key : String) : Builder
      Registry.validate_key!(key)
      Builder.new(
        key_str: key,
        ttl_val: @ttl_val,
        timeout_val: @timeout_val,
        hit_handlers: @hit_handlers.dup,
        miss_handlers: @miss_handlers.dup,
        registry: @registry
      )
    end

    # Alias for `#key`.
    def for(key : String) : Builder
      self.key(key)
    end

    # Sets the cache TTL duration. Accepts `Time::Span` or numeric milliseconds.
    def ttl(duration : Time::Span | Number) : Builder
      Builder.new(
        key_str: @key_str,
        ttl_val: Registry.normalize_ttl(duration),
        timeout_val: @timeout_val,
        hit_handlers: @hit_handlers.dup,
        miss_handlers: @miss_handlers.dup,
        registry: @registry
      )
    end

    # Sets an execution wait timeout for waiting callers.
    def timeout(duration : Time::Span) : Builder
      Builder.new(
        key_str: @key_str,
        ttl_val: @ttl_val,
        timeout_val: duration,
        hit_handlers: @hit_handlers.dup,
        miss_handlers: @miss_handlers.dup,
        registry: @registry
      )
    end

    # Registers a callback invoked when an in-flight operation or cache entry is hit.
    def on_hit(&block : String -> Nil) : Builder
      handlers = @hit_handlers.dup
      handlers << block
      Builder.new(
        key_str: @key_str,
        ttl_val: @ttl_val,
        timeout_val: @timeout_val,
        hit_handlers: handlers,
        miss_handlers: @miss_handlers.dup,
        registry: @registry
      )
    end

    # Registers a callback invoked when fresh work must be executed (cache miss).
    def on_miss(&block : String -> Nil) : Builder
      handlers = @miss_handlers.dup
      handlers << block
      Builder.new(
        key_str: @key_str,
        ttl_val: @ttl_val,
        timeout_val: @timeout_val,
        hit_handlers: @hit_handlers.dup,
        miss_handlers: handlers,
        registry: @registry
      )
    end

    # Registers a callback for either `:hit` or `:miss`.
    def on(event : Symbol | String, &block : String -> Nil) : Builder
      case event.to_s
      when "hit"
        on_hit(&block)
      when "miss"
        on_miss(&block)
      else
        raise ArgumentError.new("Unsupported Coalesce event '#{event}', expected :hit or :miss")
      end
    end

    # Executes the operation using the configured settings.
    def work(&block : -> T) : T forall T
      execute(&block)
    end

    # Alias for `#work`.
    def run(&block : -> T) : T forall T
      execute(&block)
    end

    # Alias for `#work`.
    def execute(&block : -> T) : T forall T
      Registry.validate_key!(@key_str)

      combined_hit = if @hit_handlers.empty?
                       nil
                     else
                       ->(k : String) {
                         @hit_handlers.each(&.call(k))
                         nil
                       }
                     end

      combined_miss = if @miss_handlers.empty?
                        nil
                      else
                        ->(k : String) {
                          @miss_handlers.each(&.call(k))
                          nil
                        }
                      end

      @registry.execute(
        key: @key_str,
        ttl: @ttl_val,
        timeout: @timeout_val,
        on_hit: combined_hit,
        on_miss: combined_miss,
        &block
      )
    end

    # Returns true if the key (or the builder's configured key) currently has work in flight.
    def in_flight?(key : String? = nil) : Bool
      target_key = key || @key_str
      @registry.in_flight?(target_key)
    end

    # Returns true if the key (or the builder's configured key) is currently cached.
    def cached?(key : String? = nil) : Bool
      target_key = key || @key_str
      @registry.cached?(target_key)
    end

    # Evicts the key (or the builder's configured key) from the registry.
    def invalidate(key : String? = nil) : Bool
      target_key = key || @key_str
      @registry.invalidate(target_key)
    end

    # Clears all entries from the registry.
    def reset : Nil
      @registry.reset
    end
  end
end
