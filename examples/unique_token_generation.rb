# In this example, we use Polly to help us generate unique tokens.
#
# ~ bundle exec ruby examples/unique_token_generation.rb
# User 0 was given a token of 9
# User 1 was given a token of 0
# User 2 was given a token of 5
# User 3 was given a token of 3
# User 4 was given a token of 8
# User 5 was given a token of 2
# User 6 was given a token of 6
# User 7 was given a token of 1
# User 8 was given a token of 4
# User 9 was given a token of 7
#


require 'polly'

# the world's worst database. the only thing it stores is our auth_token, but
# it _does_ enforce uniqueness. luckily this fake database is the least
# important part of this example.
class TinyDatabase
  UniquenessCheckFailed = Class.new(StandardError)

  def self.allocated_tokens
    @allocated_tokens ||= []
  end

  def self.insert!(user)
    if TinyDatabase.allocated_tokens.include?(user.auth_token)
      raise TinyDatabase::UniquenessCheckFailed.new("#{user.auth_token} already taken!")
    else
      TinyDatabase.allocated_tokens << user.auth_token
    end
  end
end

# mix this into any model that needs to generate unique tokens to be inserted
# into the database.
module UniqueToken

  # here's where the the real work happens. call this method from the model. it
  # wraps the token generator with a retry that we configure with Polly.
  def gen_token
    UniqueToken.with_retry do
      yield UniqueToken.crappy_token_generator
    end
  end

  class << self

    # cache our retry policy so it can be shared across all UniqueToken models.
    # this let's us configure it in one place and use it easily.
    def with_retry(&blk)
      @retry_policy ||= Polly.policy do
        on TinyDatabase::UniquenessCheckFailed
        try_again(forever: true)
      end
      @retry_policy.execute(&blk)
    end

    # simulate collisions that would be far, far, far less common with a more
    # realistic token generation function
    def crappy_token_generator
      (rand * 10).floor
    end
  end

end

# let's generate auth_tokens for our Users. these definitely need to be unique.
# no matter how statistically improbable it would be to have a collision with
# our awesome token generator, we still want this to be enforced at the
# database level. luckily we have TinyDatabase and our UniqueToken module to
# save us a lot of hassle.
class User
  include UniqueToken

  attr_accessor :name, :auth_token

  def initialize(name)
    @name = name
  end

  # and now the magic! generate a token and transparently retry it. if the
  # token has already been used, the TinyDatabase throws an exception and we
  # try a different one.
  def assign_auth_token!
    gen_token do |token|
      self.auth_token = token
      self.save!
    end
  end

  def save!
    TinyDatabase.insert!(self)
  end

end

# everything is set. now let's create 10 fake users and assign them our tokens.
users = 10.times.map do |i|
  u = User.new("User #{i}")
  u.assign_auth_token!
  u
end

# watch as our example comes to life, and even though our token generation
# function is awful, we get unique tokens thanks to Polly's retries.
users.each do |user|
  puts "#{user.name} was given a token of #{user.auth_token}"
end


# now if you want a better idea of how bad our token generator is, tack this
# block onto `try_again` in our policy definition.
#
# try_again(forever: true) { |ex, count, model| puts "#{count} retry for #{model.name}: #{ex}" }
#
# this should spit out all the collision details. each time we are forced to
# retry it executes this block.
