module PocketKit
  module Errors
    # Runs the command for error reports on one background thread, so a failing
    # request or job is not held up by it. Reports are sent in order.
    class Outbox
      MAX_QUEUED = 100

      def initialize
        @queue = Queue.new
        @mutex = Mutex.new
        @idle = ConditionVariable.new
        @pending = 0
      end

      # Queues a report; drops it when MAX_QUEUED are already waiting.
      def push(&delivery)
        @mutex.synchronize do
          return false if @pending >= MAX_QUEUED

          @pending += 1
          start
        end
        @queue << delivery
        true
      end

      # Waits until every queued report has been handed to the command.
      def flush(timeout = 30)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @mutex.synchronize do
          while @pending.positive?
            left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if left <= 0

            @idle.wait(@mutex, left)
          end
        end
      end

      private

      def start
        return if @thread&.alive?

        @thread = Thread.new do
          loop do
            delivery = @queue.pop
            begin
              delivery.call
            rescue StandardError
              nil
            ensure
              @mutex.synchronize do
                @pending -= 1
                @idle.broadcast
              end
            end
          end
        end
      end
    end
  end
end
