require 'spec_helper'

describe Polly do
  SampleError = Class.new(StandardError)

  def raises(ex_klass, n = Float::INFINITY)
    current_count = -1
    -> () do
      current_count += 1
      raise ex_klass.new("exceptions left: #{n - current_count}") if current_count < n
    end
  end

  let(:noop) { ->() { } }

  context "single retry" do
    let(:policy) do
      Polly.policy do
        on SampleError
        try_again
      end
    end
    let(:business_logic) { raises(SampleError) }

    it "triggers a policy's behavior on an exception" do
      times_attempted = 0
      expect {
        policy.execute do
          times_attempted += 1
          business_logic.call
        end
      }.to raise_error(SampleError)

      expect(times_attempted).to eq(2)
    end
  end

  context "multiple retries" do
    let(:policy) do
      Polly.policy do
        on SampleError
        try_again(n: 3)
      end
    end
    let(:business_logic) { raises(SampleError, 1) }

    it "does not re-raise if success within retry count" do
      times_attempted = 0
      expect {
        policy.execute do
          times_attempted += 1
          business_logic.call
        end
      }.to_not raise_error

      expect(times_attempted).to eq(2)
    end
  end

  context "retry after waiting" do
    let(:policy) do
      Polly.policy do
        on SampleError
        try_again(n: 3, after_waiting: 5)
      end
    end
    let(:business_logic) { raises(SampleError, 2) }

    it "waits between retries" do
      expect(policy).to receive(:sleep).with(5).twice

      policy.execute(&business_logic)
    end
  end

  context "when a retry is triggered" do
    let(:fake_logger) { double(:logger, log: true) }
    let(:policy) do
      Polly.policy do |calling_ctx|
        on SampleError
        try_again(n: 3) { |ex, retry_count, ctx| fake_logger.log(ex) }
      end
    end
    let(:business_logic) { raises(SampleError) }

    it "runs an side-effecting function on each retry" do
      expect { policy.execute(&business_logic) }.to raise_error(SampleError)
      expect(fake_logger).to have_received(:log).with(SampleError).exactly(3).times
    end
  end

  context "breaks a circuit" do
    let(:policy) do
      Polly.policy do
        on SampleError
        break_circuit exceptions_detected: 2, recover_after: 10
      end
    end
    let(:business_logic) { raises(SampleError, 3) }
    let(:start_time) { Time.new(2015,10,23,17,0,0) }

    before { Timecop.travel(start_time) }
    after { Timecop.return }

    it "only breaks the circuit after enough failures are detected" do
      expect { policy.execute(&business_logic) }.to raise_error(SampleError)
    end

    it "prevents any calls after the circuit breaks" do
      expect { policy.execute(&business_logic) }.to raise_error(SampleError)
      expect { policy.execute(&business_logic) }.to raise_error(SampleError)
      expect { policy.execute(&noop) }.to raise_error(Polly::BrokenCircuitError)
    end

    it "opens again after the recovery period" do
      expect { policy.execute(&business_logic) }.to raise_error(SampleError)
      expect { policy.execute(&business_logic) }.to raise_error(SampleError)
      expect { policy.execute(&noop) }.to raise_error(Polly::BrokenCircuitError)

      # jump 5 seconds ahead, make sure we're still broken
      Timecop.travel(start_time + 5.1)
      expect { policy.execute(&noop) }.to raise_error(Polly::BrokenCircuitError)

      # jump 10 seconds ahead in time, we should be open for business
      Timecop.travel(start_time + 10.1)

      expect { policy.execute(&noop) }.not_to raise_error
      expect { policy.execute(&business_logic) }.to raise_error(SampleError)
    end

  end
end

