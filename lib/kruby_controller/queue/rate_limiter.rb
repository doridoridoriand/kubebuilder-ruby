# frozen_string_literal: true

module KrubyController
  module Queue
    # Per-key exponential backoff for failed reconciles, mirroring
    # controller-runtime's ItemExponentialFailureRateLimiter: the n-th
    # consecutive failure for a key waits base * 2**(n-1) seconds, capped at
    # max. Keys are independent: a failing key never slows down others.
    #
    #   limiter = ExponentialBackoffRateLimiter.new(base: 5.0, max: 300.0)
    #   limiter.backoff("default/foo") # => 5.0
    #   limiter.backoff("default/foo") # => 10.0
    #   limiter.forget("default/foo")  # successful reconcile resets the count
    class ExponentialBackoffRateLimiter
      DEFAULT_BASE = 5.0
      DEFAULT_MAX = 300.0

      def initialize(base: DEFAULT_BASE, max: DEFAULT_MAX)
        raise ArgumentError, "base must be positive" unless base.positive?
        raise ArgumentError, "max must be positive" unless max.positive?

        @base = base
        @max = max
        @failures = Hash.new(0)
        @mutex = Mutex.new
      end

      # Records one failure for +key+ and returns the delay (seconds) the
      # next attempt should be postponed by.
      def backoff(key)
        @mutex.synchronize do
          @failures[key] += 1
          [@max, @base * (2**(@failures[key] - 1))].min
        end
      end

      # Clears the failure count for +key+ (call after a successful
      # reconcile so the next failure starts from the base delay again).
      def forget(key)
        @mutex.synchronize { @failures.delete(key) }
      end

      # Number of consecutive failures currently recorded for +key+.
      def failures(key)
        @mutex.synchronize { @failures[key] }
      end

      attr_reader :base, :max
    end
  end
end
