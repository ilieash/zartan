class Site < ActiveRecord::Base
  has_many :proxy_performances, dependent: :destroy, inverse_of: :site
  has_many :proxies, through: :proxy_performances
  
  # Redis-backed properties
  include Redis::Objects
  hash_key :proxy_pool
  sorted_set :proxy_successes
  sorted_set :proxy_failures
  
  def enable_proxy(proxy)
    proxy_pool[proxy.id] = proxy.to_json
  end
  
  def disable_proxy(proxy)
    proxy_id = proxy.id
    redis.multi do
      proxy_pool.delete(proxy_id)
      proxy_successes.delete(proxy_id)
      proxy_failures.delete(proxy_id)
    end
  end
  
  def proxy_succeeded!(proxy)
    proxy_successes.increment(proxy.id)
  end
  
  def proxy_failed!(proxy)
    conf = Zartan::Config.new
    num_failures = proxy_failures.increment(proxy.id)
    if num_failures >= conf['failure_threshold'].to_i
      self.class.examine_health! self.id, proxy.id
    end
  end

  def add_proxies
    
  end
  
  class << self
    def examine_health!(site_id, proxy_id)
      raise NotImplementedError
    end
  end
end
