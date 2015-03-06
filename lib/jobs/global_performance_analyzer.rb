module Jobs
  class GlobalPerformanceAnalyzer
    class << self
      def queue
        :default
      end

      def perform
        threads = Site.all.map do |site|
          Thread.new {site.global_performance_analysis!}
        end
        threads.each(&:join)
      end
    end
  end
end
