module Coalesce
  # Base error class for all `Coalesce` exceptions.
  class Error < Exception
  end

  # Raised when a coalescing key is invalid (e.g. empty or whitespace-only).
  class KeyError < Error
    getter key : String

    def initialize(@key : String)
      super("Coalesce key must be a non-empty string, got: #{@key.inspect}")
    end
  end

  # Raised when concurrent callers request the same key with incompatible return types.
  class TypeMismatchError < Error
    getter key : String
    getter expected_type : String

    def initialize(@key : String, @expected_type : String)
      super("Coalesce key '#{@key}' is currently in flight with an incompatible return type (expected #{@expected_type})")
    end
  end

  # Raised when a caller waits longer than the configured timeout duration for an in-flight operation.
  class TimeoutError < Error
    getter key : String
    getter timeout : Time::Span

    def initialize(@key : String, @timeout : Time::Span)
      super("Timed out waiting #{@timeout.total_milliseconds.round(2)}ms for in-flight key '#{@key}'")
    end
  end

  # Raised by the builder API when execution is requested without providing a work block.
  class MissingWorkError < Error
    def initialize
      super("No work block provided. Call `.work { ... }` or `.run { ... }` before executing.")
    end
  end
end
