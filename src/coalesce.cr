require "./coalesce/version"
require "./coalesce/errors"
require "./coalesce/flight"
require "./coalesce/registry"
require "./coalesce/builder"
require "./coalesce/macros"

module Coalesce
  @@default_registry = Registry.new

  # Returns the global default registry.
  def self.default_registry : Registry
    @@default_registry
  end

  # Coalesces concurrent executions of `block` for `key` into a single shared flight.
  #
  # Additional concurrent callers for the same key await the active execution and receive
  # the shared result.
  def self.coalesce(
    key : String,
    ttl : Time::Span | Number | Nil = nil,
    timeout : Time::Span? = nil,
    on_hit : Proc(String, Nil)? = nil,
    on_miss : Proc(String, Nil)? = nil,
    &block : -> T
  ) : T forall T
    default_registry.execute(
      key: key,
      ttl: ttl,
      timeout: timeout,
      on_hit: on_hit,
      on_miss: on_miss,
      &block
    )
  end

  # Alias for `.coalesce`.
  def self.singleflight(
    key : String,
    ttl : Time::Span | Number | Nil = nil,
    timeout : Time::Span? = nil,
    on_hit : Proc(String, Nil)? = nil,
    on_miss : Proc(String, Nil)? = nil,
    &block : -> T
  ) : T forall T
    default_registry.execute(
      key: key,
      ttl: ttl,
      timeout: timeout,
      on_hit: on_hit,
      on_miss: on_miss,
      &block
    )
  end

  # Returns true if `key` currently has work in flight.
  def self.in_flight?(key : String) : Bool
    default_registry.in_flight?(key)
  end

  # Returns true if `key` currently has an unexpired cached value.
  def self.cached?(key : String) : Bool
    default_registry.cached?(key)
  end

  # Evicts `key` from the default registry.
  def self.invalidate(key : String) : Bool
    default_registry.invalidate(key)
  end

  # Clears all entries from the default registry.
  def self.reset : Nil
    default_registry.reset
  end

  # Starts a fluent `Builder` targeting `key`.
  def self.key(key : String) : Builder
    Builder.new(registry: default_registry).key(key)
  end

  # Alias for `.key`.
  def self.for(key : String) : Builder
    self.key(key)
  end
end
