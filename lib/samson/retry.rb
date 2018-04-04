# frozen_string_literal: true
module Samson
  module Retry
    def self.retry_when_not_unique(&block)
      with_retries [ActiveRecord::RecordNotUnique], 1, &block
    end

    def self.with_retries(errors, count, options = nil)
      check = options && options[:if]
      yield
    rescue *errors
      count -= 1
      count >= 0 && (!check || check.call($!)) ? retry : raise
    end
  end
end
