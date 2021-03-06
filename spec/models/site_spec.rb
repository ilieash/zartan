require 'rails_helper'

RSpec.describe Site, type: :model do
  let(:site) {create(:site)}
  let(:proxy) {create(:proxy)}
  let(:proxy2) {create(:proxy, :host => 'host2')}
  let(:proxy_performance) do
    create(:proxy_performance, :proxy => proxy, :site => site)
  end

  describe "redis interactions", redis:true do

    describe "adding and removing proxies" do
      it "should add proxies to the proxy pool" do
        site.enable_proxy proxy

        expect(
          @redis.zscore( site.proxy_pool.key, proxy.id )
        ).to eq(0)
      end


      it "should remove all traces in redis of disabled proxies" do
        Zartan::Config.new['failure_threshold'] = 100
        site.enable_proxy proxy
        site.proxy_succeeded! proxy
        site.proxy_failed! proxy
        expect(proxy).to receive(:queue_decommission)

        site.send(:proxy_removal_wrapper, proxy) {}

        expect(@redis.zscore( site.proxy_pool.key, proxy.id )).to be_nil
        expect(@redis.zscore( site.proxy_successes.key, proxy.id )).to be_nil
        expect(@redis.zscore( site.proxy_failures.key, proxy.id )).to be_nil
      end
    end

    it "should calculate how many proxies need to be added" do
      old_proxies_needed = site.num_proxies_needed
      site.enable_proxy proxy

      expect(site.num_proxies_needed).to eq old_proxies_needed-1
    end

    context '#latest_proxy_info' do
      it 'retrieves the latest proxy info' do
        now = Time.now.to_i
        site.proxy_pool[1] = now
        site.proxy_pool[2] = now - 30.seconds

        proxy_info = site.send(:latest_proxy_info)

        expect(proxy_info.proxy_id).to eq "1"
        expect(proxy_info.proxy_ts).to eq now
      end

      it 'has nil values if there is no proxy info' do
        proxy_info = site.send(:latest_proxy_info)

        expect(proxy_info.proxy_id).to be_nil
        expect(proxy_info.proxy_ts).to be_nil
      end
    end

    context '#active_performance?' do
      it 'should identify a disabled proxy/site relationship' do
        proxy_performance.soft_delete
        proxy_performance.save

        expect(site.active_performance?(proxy)).to be_falsey
      end

      it 'should identify active proxy/site relationship' do
        proxy_performance.save

        expect(site.active_performance?(proxy)).to be_truthy
      end        
    end

    describe "recording proxy success" do
      it "should ignore disabled proxies" do
        expect(site).to receive(:active_performance?).and_return(false)
        expect(site).to receive(:proxy_pool_lock).never

        site.proxy_succeeded! proxy
      end

      it "should record proxy successes" do
        value = 10
        @redis.zadd( site.proxy_successes.key, value, proxy.id )
        expect(site).to receive(:active_performance?).and_return(true)

        site.proxy_succeeded! proxy

        expect(
          @redis.zscore( site.proxy_successes.key, proxy.id )
        ).to eq(value + 1)
      end


      it "should update the proxy's timestamp" do
        site.enable_proxy proxy
        expect(site).to receive(:active_performance?).and_return(true)

        site.proxy_succeeded! proxy

        expect(
          @redis.zscore( site.proxy_pool.key, proxy.id )
        ).to be_within(10).of(Time.now.to_i)
      end
    end


    describe "recording proxy failure" do
      it "should ignore disabled proxies" do
        expect(site).to receive(:active_performance?).and_return(false)
        expect(site).to receive(:proxy_pool_lock).never

        site.proxy_failed! proxy
      end

      it "should record proxy failures" do
        value = 10
        @redis.zadd( site.proxy_failures.key, value, proxy.id )
        Zartan::Config.new['failure_threshold'] = 12
        expect(site).to receive(:active_performance?).and_return(true)

        site.proxy_failed! proxy

        expect(Site).not_to receive(:examine_health!)
        expect(
          @redis.zscore( site.proxy_failures.key, proxy.id )
        ).to eq(value + 1)
      end


      it "should notify the system when too many failures have occurred" do
        value = 10
        @redis.zadd( site.proxy_failures.key, value, proxy.id )
        Zartan::Config.new['failure_threshold'] = 11
        expect(Site).to receive(:examine_health!).with(site.id, proxy.id)
        expect(site).to receive(:active_performance?).and_return(true)

        site.proxy_failed! proxy

        expect(
          @redis.zscore( site.proxy_failures.key, proxy.id )
        ).to eq(value + 1)
      end


      it "should update the proxy's timestamp" do
        site.enable_proxy proxy
        Zartan::Config.new['failure_threshold'] = 10
        expect(site).to receive(:active_performance?).and_return(true)

        site.proxy_failed! proxy

        expect(
          @redis.zscore( site.proxy_pool.key, proxy.id )
        ).to be_within(10).of(Time.now.to_i)
      end
    end


    describe "proxy selection" do
      it "should return NoProxy when there are none" do
        expect(site.select_proxy).to eq(Proxy::NoProxy)
      end


      it "should return a Proxy when there are any" do
        site.enable_proxy proxy

        expect(site.select_proxy).to be_instance_of(Proxy)
      end


      it "should return the least recently used proxy when there are several" do
        proxy2 = create(:proxy, host: 'example.org')
        base_ts = Time.now.to_i
        @redis.zadd( site.proxy_pool.key, base_ts, proxy.id )
        @redis.zadd( site.proxy_pool.key, (base_ts - 1), proxy2.id )

        expect(site.select_proxy).to eq(proxy2)
      end


      it "should update the timestamp of the proxy it selects" do
        site.enable_proxy proxy

        site.select_proxy

        expect(
          @redis.zscore( site.proxy_pool.key, proxy.id )
        ).to be_within(10).of(Time.now.to_i)
      end


      it "should return NotReady when there are no sufficiently old proxies" do
        base_ts = Time.now.to_i - 60
        @redis.zadd( site.proxy_pool.key, base_ts, proxy.id )

        expect(site.select_proxy(120)).to be_instance_of(Proxy::NotReady)
      end


      it "should set the NotReady's timeout appropriately" do
        base_ts = Time.now.to_i - 60
        @redis.zadd( site.proxy_pool.key, base_ts, proxy.id )

        expect(site.select_proxy(120).timeout).to be_between(50,60).inclusive
      end


      it "should return a proxy object when there are sufficiently old proxies" do
        base_ts = Time.now.to_i - 60
        @redis.zadd( site.proxy_pool.key, base_ts, proxy.id )
        expect(site.select_proxy(60)).to eq(proxy)
      end
    end

    it "should add proxies to both redis and postgres" do
      expect(site).to receive(:restore_or_create_performances)
      expect(site).to receive(:enable_proxy).twice
      expect(site).to receive(:transaction).and_yield

      site.add_proxies(proxy, proxy2)
    end

    context '#generate_proxy_report' do
      it "resets successes and failures and returns their former values" do
        former_successes = 15
        @redis.zadd( site.proxy_successes.key, former_successes, proxy.id )
        former_failures = 10
        @redis.zadd( site.proxy_failures.key, former_failures, proxy.id )
        expect(site).to receive(:update_long_term_performance)

        report = site.send(:generate_proxy_report, proxy)

        expect(report.times_succeeded).to eq former_successes
        expect(report.times_failed).to eq former_failures
        expect(
          @redis.zscore( site.proxy_successes.key, proxy.id )
        ).to eq(0)
        expect(
          @redis.zscore( site.proxy_failures.key, proxy.id )
        ).to eq(0)
      end
    end

    context 'destruction' do
      it 'destroys the redis constructs when site is destroyed' do
        site.proxy_successes[proxy.id] = 0
        site.proxy_failures[proxy.id] = 0
        site.proxy_pool[proxy.id] = 0
        expect(@redis.keys.length).to eq 3

        site.destroy

        expect(@redis.keys.length).to eq 0
      end
    end

    context '#proxy_too_old?' do
      it 'identifies new proxies' do
        now = Time.now.to_i
        @redis.zadd( site.proxy_pool.key, now, proxy.id )

        expect(site.send(:proxy_too_old?, proxy)).to be_falsey
      end

      it 'identifies old proxies' do
        now = Time.now.to_i - site.send(:proxy_age_timeout) - 1
        @redis.zadd( site.proxy_pool.key, now, proxy.id )

        expect(site.send(:proxy_too_old?, proxy)).to be_truthy
      end

      it 'treats untouched proxies as new' do
        @redis.zadd( site.proxy_pool.key, 0, proxy.id )

        expect(site.send(:proxy_too_old?, proxy)).to be_falsey
      end
    end
  end

  describe 'PerformanceReport' do
    it 'calculates the total number of successes + failures' do
      report = Site::PerformanceReport.new(1, 6)
      expect(report.total).to eq 7
    end
  end

  context '#global_performance_analysis!' do
    before :each do
      @proxy_info = double('proxy_info')
      expect(site).to receive(:latest_proxy_info).and_return(@proxy_info)
    end

    it "disables bad proxies and requests more" do
      proxy_performance.save
      expect(site).to receive(:disable_proxy_if_bad)
      expect(@proxy_info).to receive(:proxy_ts).and_return(Time.now.to_i)
      expect(site).to receive(:proxy_age_timeout).and_return(60)
      expect(site).to receive(:request_more_proxies)

      site.global_performance_analysis!
    end

    it "doesn't request more proxies if there were initially no proxies" do
      expect(@proxy_info).to receive(:proxy_ts).and_return(nil)
      expect(site).to receive(:request_more_proxies).never

      site.global_performance_analysis!
    end

    it "doesn't request more proxies if there is no recent scrape" do
      expect(@proxy_info).to receive(:proxy_ts).and_return(Time.now.to_i - 60)
      expect(site).to receive(:proxy_age_timeout).and_return(30)
      expect(site).to receive(:request_more_proxies).never

      site.global_performance_analysis!
    end
  end

  context '#proxy_performance_analysis!' do

    it "should run a performance analysis on a single proxy" do
      expect(site).to receive(:disable_proxy_if_bad)
      expect(site).to receive(:request_more_proxies)
      site.proxy_performance_analysis! proxy
    end
  end

  context '#restore_or_create_performances' do
    it 'restores or creates multiple proxies' do
      expect(ProxyPerformance).to receive(:restore_or_create).twice

      site.send(:restore_or_create_performances, [proxy, proxy2])
    end
  end

  context '#disable_proxy_if_bad' do

    context "proxy is not too old" do
      before(:each) do
        expect(site).to receive(:proxy_too_old?).and_return(false)
      end

      it "should not disable a successful proxy" do
        report = Site::PerformanceReport.new(10, 1)
        expect(site).to receive(:generate_proxy_report).and_return(report)
        expect(site).to receive(:success_ratio_threshold).and_return(0.25)
        expect(site).to receive(:disable_proxy).never
        expect(site).to receive(:large_enough_sample?).and_return(true)

        site.send(:disable_proxy_if_bad, proxy)
      end

      it "should disable an unsuccessful proxy" do
        report = Site::PerformanceReport.new(10, 100)
        expect(site).to receive(:generate_proxy_report).and_return(report)
        expect(site).to receive(:success_ratio_threshold).and_return(0.25)
        expect(site).to receive(:disable_proxy)
        expect(site).to receive(:large_enough_sample?).and_return(true)

        site.send(:disable_proxy_if_bad, proxy)
      end

      it "should not disable an proxy if we do not have enough samples" do
        report = Site::PerformanceReport.new(10, 1)
        expect(site).to receive(:generate_proxy_report).and_return(report)
        expect(site).to receive(:success_ratio_threshold).never
        expect(site).to receive(:disable_proxy).never
        expect(site).to receive(:large_enough_sample?).and_return(false)

        site.send(:disable_proxy_if_bad, proxy)
      end

      it "should ignore sample size when requested" do
        report = Site::PerformanceReport.new(10, 100)
        expect(site).to receive(:generate_proxy_report).and_return(report)
        expect(site).to receive(:success_ratio_threshold).and_return(0.25)
        expect(site).to receive(:disable_proxy)
        expect(site).to receive(:large_enough_sample?).never

        site.send(:disable_proxy_if_bad, proxy, {trust_sample_size: true})
      end
    end
  end

  context '#large_enough_sample?' do
    it 'determines we have a large enough sample' do
      report = double('report', :total => 12)
      expect(site).to receive(:failure_threshold).and_return(9)
      expect(site).to receive(:success_ratio_threshold).and_return(0.25)

      expect(site.send(:large_enough_sample?, report)).to be_truthy
    end

    it 'determines we do not have a large enough sample' do
      report = double('report', :total => 11)
      expect(site).to receive(:failure_threshold).and_return(9)
      expect(site).to receive(:success_ratio_threshold).and_return(0.25)

      expect(site.send(:large_enough_sample?, report)).to be_falsey
    end
  end

  context '#request_more_proxies' do
    it "does nothing if we don't need more proxies" do
      expect(site).to receive(:num_proxies).and_return(5)
      expect(site).to receive(:min_proxies).and_return(5)
      expect(ProxyRequestor).to receive(:new).never

      site.request_more_proxies
    end

    it "requests more proxies if we need more" do
      expect(site).to receive(:num_proxies).and_return(4)
      expect(site).to receive(:min_proxies).and_return(5)
      requestor = double('requestor', :run => double)
      expect(ProxyRequestor).to receive(:new).and_return(requestor)

      site.request_more_proxies
    end
  end

  context '#success_ratio_threshold' do
    it 'retrieves the success ratio threshold config as a float' do
      Zartan::Config.new[:success_ratio_threshold] = 0.25
      expect(site.send(:success_ratio_threshold)).to eq 0.25
    end
  end

  context '#generate_proxy_report' do
    before :each do
      expect(site).to receive(:update_long_term_performance)
    end

    it 'returns NoPerformanceReport if the proxy lock fails' do
      expect(site.proxy_pool_lock).to receive(:lock)
      expect(Site::PerformanceReport).to receive(:new).never

      expect(site.send(:generate_proxy_report, proxy)).
        to be Site::NoPerformanceReport
    end
  end

  context '#update_long_term_performance' do
    it 'updates long term performance of a site/proxy combination from redis' do
      proxy_performance.save
      expect(ProxyPerformance).to receive(:find_or_create_by).
        and_return(proxy_performance)
      times_succeeded = 20
      times_failed = 3
      report = Site::PerformanceReport.new(times_succeeded, times_failed)
      expect(proxy_performance).to receive(:increment).with(
        :times_succeeded => times_succeeded,
        :times_failed => times_failed
      )

      site.send(:update_long_term_performance, proxy, report)
    end
  end

  context '#examine_health!' do
    it 'enqueues a job to examine the site/proxy health' do
      expect(Resque).to receive(:enqueue)

      Site.examine_health! site.id, proxy.id
    end
  end
end
