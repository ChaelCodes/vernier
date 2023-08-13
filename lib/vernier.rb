# frozen_string_literal: true

require_relative "vernier/version"
require_relative "vernier/collector"
require_relative "vernier/vernier"
require_relative "vernier/output/firefox"
require_relative "vernier/output/top"

module Vernier
  class Error < StandardError; end

  class Result
    attr_reader :stack_table, :frame_table, :func_table
    attr_reader :markers

    attr_accessor :pid, :start_time, :end_time
    attr_accessor :threads
    attr_accessor :meta

    # TODO: remove these
    def weights; threads.values.flat_map { _1[:weights] }; end
    def samples; threads.values.flat_map { _1[:samples] }; end
    def sample_categories; threads.values.flat_map { _1[:sample_categories] }; end

    # Realtime in milliseconds since the unix epoch
    def started_at
      started_at_mono_ns = meta[:started_at]
      current_time_mono_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      current_time_real_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      (current_time_real_ns - current_time_mono_ns + started_at_mono_ns)
    end

    def to_gecko
      Output::Firefox.new(self).output
    end

    def write(out:)
      File.write(out, to_gecko)
    end

    def each_sample
      return enum_for(__method__) unless block_given?
      samples.size.times do |sample_idx|
        weight = weights[sample_idx]
        stack_idx = samples[sample_idx]
        yield stack(stack_idx), weight
      end
    end

    class BaseType
      attr_reader :result, :idx
      def initialize(result, idx)
        @result = result
        @idx = idx
      end

      def to_s
        idx.to_s
      end

      def inspect
        "#<#{self.class}\n#{to_s}>"
      end
    end

    class Func < BaseType
      def label
        result.func_table[:name][idx]
      end
      alias name label

      def filename
        result.func_table[:filename][idx]
      end

      def to_s
        "#{name} at #{filename}"
      end
    end

    class Frame < BaseType
      def label; func.label; end
      def filename; func.filename; end
      alias name label

      def func
        func_idx = result.frame_table[:func][idx]
        Func.new(result, func_idx)
      end

      def line
        result.frame_table[:line][idx]
      end

      def to_s
        "#{func}:#{line}"
      end
    end

    class Stack < BaseType
      def each_frame
        return enum_for(__method__) unless block_given?

        stack_idx = idx
        while stack_idx
          frame_idx = result.stack_table[:frame][stack_idx]
          yield Frame.new(result, frame_idx)
          stack_idx = result.stack_table[:parent][stack_idx]
        end
      end

      def leaf_frame_idx
        result.stack_table[:frame][idx]
      end

      def leaf_frame
        Frame.new(result, leaf_frame_idx)
      end

      def frames
        each_frame.to_a
      end

      def to_s
        arr = []
        each_frame do |frame|
          arr << frame.to_s
        end
        arr.join("\n")
      end
    end

    def stack(idx)
      Stack.new(self, idx)
    end

    def total_bytes
      weights.sum
    end
  end

  def self.trace(mode: :wall, out: nil, interval: nil)
    collector = Vernier::Collector.new(mode, { interval: })
    collector.start

    result = nil
    begin
      yield
    ensure
      result = collector.stop
    end

    if out
      File.write(out, Output::Firefox.new(result).output)
    end
    result
  end

  def self.trace_retained(out: nil, gc: true)
    3.times { GC.start } if gc

    start_time = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)

    collector = Vernier::Collector.new(:retained)
    collector.start

    result = nil
    begin
      yield
    ensure
      result = collector.stop
      end_time = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      result.pid = Process.pid
      result.start_time = start_time
      result.end_time = end_time
    end

    if out
      result.write(out:)
    end
    result
  end

  class Collector
    def self.new(mode, options = {})
      _new(mode, options)
    end
  end
end
