# encoding: UTF-8

require 'benchmark'
require 'prometheus/client'

module Prometheus
  module Middleware
    # Collector is a Rack middleware that provides a sample implementation of a
    # HTTP tracer.
    #
    # By default metrics are registered on the global registry. Set the
    # `:registry` option to use a custom registry.
    #
    # By default metrics all have the prefix "http_server". Set to something
    # else if you like.
    #
    # The request counter metric is broken down by code, method and path by
    # default. Set the `:counter_label_builder` option to use a custom label
    # builder.
    #
    # The request duration metric is broken down by method and path by default.
    # Set the `:duration_label_builder` option to use a custom label builder.
    #
    # Label Builder functions will receive a Rack env and a status code, and must
    # return a hash with the labels for that request. They must also accept an empty
    # env, and return a hash with the correct keys. This is necessary to initialize
    # the metrics with the correct set of labels.
    class Collector
      attr_reader :app, :registry

      def initialize(app, options = {})
        @app = app
        @registry = options[:registry] || Client.registry
        @metrics_prefix = options[:metrics_prefix] || 'http_server'

        init_request_metrics
        init_exception_metrics
      end

      def call(env) # :nodoc:
        trace(env) { @app.call(env) }
      end

      protected

      def init_request_metrics
        counter_name    = "#{@metrics_prefix}_requests_total"
        histogram_name  = "#{@metrics_prefix}_request_duration_seconds"

        @requests = @registry.get(counter_name) || @registry.counter(
          counter_name.to_sym,
          docstring:
            'The total number of HTTP requests handled by the Rack application.',
          labels: %i[code method path]
        )
        @durations = @registry.get(histogram_name) || @registry.histogram(
          histogram_name.to_sym,
          docstring: 'The HTTP response duration of the Rack application.',
          labels: %i[method path]
        )
      end

      def init_exception_metrics
        exception_counter_name = "#{@metrics_prefix}_exceptions_total"

        @exceptions = @registry.get(exception_counter_name) || @registry.counter(
          exception_counter_name.to_sym,
          docstring: 'The total number of exceptions raised by the Rack application.',
          labels: [:exception]
        )
      end

      def trace(env)
        response = nil
        duration = Benchmark.realtime { response = yield }
        record(env, response.first.to_s, duration)
        return response
      rescue => exception
        @exceptions.increment(labels: { exception: exception.class.name })
        raise
      end

      def record(env, code, duration)
        counter_labels = {
          code:   code,
          method: env['REQUEST_METHOD'].downcase,
          path:   strip_ids_from_path(env['PATH_INFO']),
        }

        duration_labels = {
          method: env['REQUEST_METHOD'].downcase,
          path:   strip_ids_from_path(env['PATH_INFO']),
        }

        @requests.increment(labels: counter_labels)
        @durations.observe(duration, labels: duration_labels)
      rescue
        # TODO: log unexpected exception during request recording
        nil
      end

      def strip_ids_from_path(path)
        path
          .gsub(%r{/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(/|$)}, '/:uuid\\1')
          .gsub(%r{/\d+(/|$)}, '/:id\\1')
      end
    end
  end
end
