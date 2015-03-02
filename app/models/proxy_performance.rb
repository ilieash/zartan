class ProxyPerformance < ActiveRecord::Base
  belongs_to :proxy, inverse_of: :proxy_performances
  belongs_to :site, inverse_of: :proxy_performances

  include Concerns::SoftDeletable

  def increment(times_succeeded:, times_failed:)
    self.times_succeeded += times_succeeded
    self.times_failed += times_failed
    self.save
  end
end
