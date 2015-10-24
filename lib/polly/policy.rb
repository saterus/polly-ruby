module Polly
  class Policy

    def self.configure(&blk)
      policy = new(blk.binding.receiver)
      policy.instance_exec(&blk)
      policy
    end

    def initialize(original_calling_context)
      @handled_exceptions = []
      @max_retries = nil
      @retries = nil
      @on_retry = nil
      @fail_count = 0
      @circuit_state = :closed
      @fuse_limit = nil
      @circuit_recovery_delay = nil
      @circuit_broken_at = nil
      @original_calling_context = original_calling_context
    end

    def on(*exceptions)
      @handled_exceptions = exceptions
    end

    def try_again(n: 1, forever: nil, after_waiting: nil, &on_retry)
      if forever
        @max_retries = @retries = Float::INFINITY
      elsif n > 0
        @max_retries = @retries = n
      else
        raise ArgumentError.new("Invalid retry count")
      end

      @wait = after_waiting if after_waiting

      if block_given?
        @on_retry = on_retry
      end
    end

    def break_circuit(exceptions_detected:, recover_after:)
      @fuse_limit = exceptions_detected
      @circuit_recovery_delay = recover_after
    end

    def execute(&blk)
      begin
        if @circuit_state == :open
          if should_reconnect_circuit?
            @circuit_state = :half_open
            @circuit_broken_at = nil
          else
            raise Polly::BrokenCircuitError.new("Time remaining: #{(circuit_recovers_at - Time.now).round(5)}s")
          end
        end

        result = blk.call

        if @circuit_state == :half_open
          @circuit_state = :closed
        end
        @fail_count = 0
        @retries = @max_retries

        result
      rescue *@handled_exceptions => ex
        @fail_count += 1

        if circuit_should_break?
          @circuit_state = :open
          @circuit_broken_at = Time.now
        end

        if @retries
          if @wait
            sleep(@wait)
          end

          if @retries > 0
            @retries -= 1
            if @on_retry
              @original_calling_context.instance_exec(ex, @fail_count, blk.binding.receiver, &@on_retry)
            end
            retry
          else
            raise
          end
        else
          raise
        end
      end
    end

    private

    def circuit_should_break?
      # circuit breaking isn't even turned on
      return false if @fuse_limit.nil?

      # we've just re-enabled the circuit for the first time and immediately failed
      return true if @circuit_state == :half_open

      # we have now failed more times than we are allowed
      @fail_count >= @fuse_limit
    end

    def should_reconnect_circuit?
      Time.now > circuit_recovers_at
    end

    def circuit_recovers_at
      @circuit_broken_at + @circuit_recovery_delay
    end

  end
end
