require "polly/version"
require "polly/policy"

module Polly

  BrokenCircuitError = Class.new(StandardError)

  def self.policy(&blk)
    Policy.configure(&blk)
  end

end
