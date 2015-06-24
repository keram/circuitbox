class Circuitbox
  class CircuitBreaker
    attr_accessor :service, :circuit_options, :exceptions, :partition,
                  :logger, :stat_store, :circuit_store, :notifier

    DEFAULTS = {
      sleep_window:     300,
      volume_threshold: 5,
      error_threshold:  50,
      timeout_seconds:  1,
      time_window:      60,
    }

    #
    # Configuration options
    #
    # `sleep_window`      - seconds to sleep the circuit
    # `volume_threshold`  - number of requests before error rate calculation occurs
    # `error_threshold`   - percentage of failed requests needed to trip circuit
    # `timeout_seconds`   - seconds until it will timeout the request
    # `exceptions`        - exceptions other than Timeout::Error that count as failures
    # `time_window`       - interval of time used to calculate error_rate (in seconds) - default is 60s
    #
    def initialize(service, options = {})
      @service = service
      @circuit_options = options
      @circuit_store   = options.fetch(:cache) { Circuitbox.circuit_store }
      @notifier        = options.fetch(:notifier_class) { NullNotifier }

      @exceptions = options.fetch(:exceptions) { [] }
      @exceptions = [Timeout::Error] if @exceptions.blank?

      @logger     = defined?(Rails) ? Rails.logger : Logger.new(STDOUT)
      @stat_store = options.fetch(:stat_store) { Circuitbox.stat_store }
      @time_class   = options.fetch(:time_class) { Time }
      sanitize_options
    end

    def option_value(name)
      value = circuit_options.fetch(name) { DEFAULTS.fetch(name) }
      value.is_a?(Proc) ? value.call : value
    end

    def run!(run_options = {})
      @partition = run_options.delete(:partition) # sorry for this hack.

      if open?
        logger.debug "[CIRCUIT] open: skipping #{service}"
        open! unless open_flag?
        raise Circuitbox::OpenCircuitError.new(service)
      else
        close! if was_open?
        logger.debug "[CIRCUIT] closed: querying #{service}"

        begin
          response = if exceptions.include? Timeout::Error
            timeout_seconds = run_options.fetch(:timeout_seconds) { option_value(:timeout_seconds) }
            timeout (timeout_seconds) { yield }
          else
            yield
          end

          logger.debug "[CIRCUIT] closed: #{service} querie success"
          success!
        rescue *exceptions => exception
          logger.debug "[CIRCUIT] closed: detected #{service} failure"
          failure!
          open! if half_open?
          raise Circuitbox::ServiceFailureError.new(service, exception)
        end
      end

      return response
    end

    def run(run_options = {})
      begin
        run!(run_options, &Proc.new)
      rescue Circuitbox::Error
        nil
      end
    end

    def open?
      if open_flag?
        true
      elsif passed_volume_threshold? && passed_rate_threshold?
        true
      else
        false
      end
    end

    def stats(partition)
      @partition = partition
      options = { without_partition: @partition.blank? }

      stats = []
      end_time = Time.now
      hour = 48.hours.ago.change(min: 0, sec: 0)
      while hour <= end_time
        time_object = hour

        60.times do |i|
          time = time_object.change(min: i, sec: 0).to_i
          stats << stats_for_time(time, options) unless time > Time.now.to_i
        end

        hour += 3600
      end
      stats
    end

    def error_rate(failures = failure_count, success = success_count)
      all_count = failures + success
      return 0.0 unless all_count > 0
      failure_count.to_f / all_count.to_f * 100
    end

    def failure_count
      circuit_store.read(stat_storage_key(:failure)).to_i
    end

    def success_count
      circuit_store.read(stat_storage_key(:success)).to_i
    end

    def try_close_next_time
      circuit_store.delete(storage_key(:asleep))
    end

  private
    def open!
      log_event :open
      logger.debug "[CIRCUIT] opening #{service} circuit"
      circuit_store.write(storage_key(:asleep), true, expires_in: option_value(:sleep_window).seconds)
      half_open!
      was_open!
    end

    ### BEGIN - all this is just here to produce a close notification
    def close!
      log_event :close
      circuit_store.delete(storage_key(:was_open))
    end

    def was_open!
      circuit_store.write(storage_key(:was_open), true)
    end

    def was_open?
      circuit_store.read(storage_key(:was_open)).present?
    end
    ### END

    def half_open!
      circuit_store.write(storage_key(:half_open), true)
    end

    def open_flag?
      circuit_store.read(storage_key(:asleep)).present?
    end

    def half_open?
      circuit_store.read(storage_key(:half_open)).present?
    end

    def passed_volume_threshold?
      success_count + failure_count > option_value(:volume_threshold)
    end

    def passed_rate_threshold?
      read_and_log_error_rate >= option_value(:error_threshold)
    end

    def read_and_log_error_rate
      failures = failure_count
      success  = success_count
      rate = error_rate(failures, success)
      log_metrics(rate, failures, success)
      rate
    end

    def success!
      log_event :success
      circuit_store.delete(storage_key(:half_open))
    end

    def failure!
      log_event :failure
    end

    # Store success/failure/open/close data in memcache
    def log_event(event)
      notifier.new(service,partition).notify(event)
      log_event_to_process(event)

      if stat_store.present?
        log_event_to_stat_store(stat_storage_key(event))
        log_event_to_stat_store(stat_storage_key(event, without_partition: true))
      end
    end

    def log_metrics(error_rate, failures, successes)
      n = notifier.new(service,partition)
      n.metric_gauge(:error_rate, error_rate)
      n.metric_gauge(:failure_count, failures)
      n.metric_gauge(:success_count, successes)
    end

    def sanitize_options
      sleep_window = option_value(:sleep_window)
      time_window  = option_value(:time_window)
      if sleep_window < time_window
        notifier.new(service,partition).notify_warning("sleep_window:#{sleep_window} is shorter than time_window:#{time_window}, the error_rate could not be reset properly after a sleep. sleep_window as been set to equal time_window.")
        @circuit_options[:sleep_window] = option_value(:time_window)
      end
    end

    # When there is a successful response within a stat interval, clear the failures.
    def clear_failures!
      circuit_store.write(stat_storage_key(:failure), 0, raw: true)
    end

    # Logs to process memory.
    def log_event_to_process(event)
      key = stat_storage_key(event)
      if circuit_store.read(key, raw: true)
        circuit_store.increment(key)
      else
        circuit_store.write(key, 1, raw: true)
      end
    end

    # Logs to Memcache.
    def log_event_to_stat_store(key)
      if stat_store.read(key, raw: true)
        stat_store.increment(key)
      else
        stat_store.write(key, 1, raw: true)
      end
    end

    # For returning stale responses when the circuit is open
    def response_key(args)
      Digest::SHA1.hexdigest(storage_key(:cache, args.inspect.to_s))
    end

    def stat_storage_key(event, options = {})
      storage_key(:stats, align_time_on_minute, event, options)
    end

    # return time representation in seconds
    def align_time_on_minute(time=nil)
      time      ||= @time_class.now.to_i
      time_window = option_value(:time_window)
      time - ( time % time_window ) # remove rest of integer division
    end

    def storage_key(*args)
      options = args.extract_options!

      key = if options[:without_partition]
        "circuits:#{service}:#{args.join(":")}"
      else
        "circuits:#{service}:#{partition}:#{args.join(":")}"
      end

      return key
    end

    def timeout(timeout_seconds, &block)
      Timeout::timeout(timeout_seconds) { block.call }
    end

    def self.reset
      Circuitbox.reset
    end

    def stats_for_time(time, options = {})
      stats = { time: align_time_on_minute(time) }
      [:success, :failure, :open].each do |event|
        stats[event] = stat_store.read(storage_key(:stats, time, event, options), raw: true) || 0
      end
      stats
    end
  end
end
