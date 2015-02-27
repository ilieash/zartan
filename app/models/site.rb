class Site < ActiveRecord::Base
  has_many :proxy_performances, dependent: :destroy, inverse_of: :site
  has_many :proxies, through: :proxy_performances
  
  # Redis-backed properties
  include Redis::Objects
  sorted_set :proxy_pool
  lock :proxy_pool, expiration: 60.seconds
  sorted_set :proxy_successes
  sorted_set :proxy_failures
  
  # select_proxy()
  # select_proxy(older_than)
  # Find a suitable proxy for scraping this site.
  # Parameters:
  #   older_than: Don't return a proxy that was last used more recently than
  #               `older_than` seconds ago. The default is -1 (indicating that
  #               any proxy will do, as no proxy was used more than 1 second
  #               in the future)
  # Returns:
  #   - a Proxy instance if we found one used long enough ago
  #   - Proxy::NoColdProxy(timeout) if we found an instance, but it won't be
  #     old enough until `timeout` seconds from now
  #   - Proxy::NoProxy if we didn't find any proxies at all
  def select_proxy(older_than=-1)
    proxy_id, proxy_ts = nil, nil
    # Select the least recently used proxy, get its timestamp, then update its timestamp
    proxy_pool_lock.lock do
      proxy_info = proxy_pool.range(0, 0, with_scores: true)
      proxy_id, proxy_ts = proxy_info.first
      touch(proxy_id)
    end
    
    begin
      threshold_ts = (Time.now - older_than.seconds).to_i
      if proxy_ts.nil?
        # We didn't find a proxy
        Proxy::NoProxy
      elsif proxy_ts > threshold_ts
        # The proxy we found was too recently used.
        Proxy::NoColdProxy.new(proxy_ts - threshold_ts)
      else
        Proxy.find(proxy_id)
      end
    rescue ActiveRecord::RecordNotFound => e
      Proxy::NoProxy
    end
  end
  
  def enable_proxy(proxy)
    proxy_pool_lock.lock do
      proxy_pool[proxy.id] = 0
    end
  end
  
  def disable_proxy(proxy)
    proxy_pool_lock.lock do
      proxy_pool.delete(proxy.id)
      proxy_successes.delete(proxy.id)
      proxy_failures.delete(proxy.id)
    end
  end
  
  def proxy_succeeded!(proxy)
    proxy_pool_lock.lock do
      touch(proxy.id)
      proxy_successes.increment(proxy.id)
    end
  end
  
  def proxy_failed!(proxy)
    conf = Zartan::Config.new
    failure_threshold = conf['failure_threshold'].to_i
    num_failures = 0
    proxy_pool_lock.lock do
      touch(proxy.id)
      num_failures = proxy_failures.increment(proxy.id)
    end
    if num_failures >= failure_threshold
      self.class.examine_health! self.id, proxy.id
    end
  end
  
  private
  def touch(proxy_id)
    proxy_pool[proxy_id] = Time.now.to_i unless proxy_id.nil?
  end
  
  class << self
    def examine_health!(site_id, proxy_id)
      raise NotImplementedError
    end
  end
end
