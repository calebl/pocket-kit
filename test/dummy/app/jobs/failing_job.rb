class FailingJob < ActiveJob::Base
  def perform(id)
    raise ArgumentError, "Bad record #{id}"
  end
end
