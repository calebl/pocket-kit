require "shellwords"

module PocketKit
  # Runs the owner's local command the same way for every piece.
  #
  # No shell. The environment variable is split into a fixed argument array
  # once, `--request-id <id> --json -` is appended as further arguments, and the
  # body goes on the command's stdin. Shell metacharacters stay literal
  # arguments. The command's output is discarded; past the timeout its whole
  # process group is terminated.
  module Command
    TERMINATION_GRACE = 1

    # The command in the named environment variable as an argument array, or
    # nil when it is unset, blank, or cannot be split.
    def self.from_env(name)
      return if name.blank?

      value = ENV.fetch(name, "")
      value.strip.empty? ? nil : Shellwords.split(value)
    rescue ArgumentError
      nil
    end

    # Runs the command with the request id and body. Returns true when it exits
    # within the timeout with one of sent_exit_codes.
    def self.send_report(command, request_id:, body:, timeout:, sent_exit_codes:)
      status = run([ *command, "--request-id", request_id, "--json", "-" ], body, timeout)
      status && sent_exit_codes.include?(status.exitstatus) ? true : false
    rescue SystemCallError
      false
    end

    def self.run(argv, body, timeout)
      input, writer = IO.pipe
      pid = Process.spawn(*argv, in: input, out: File::NULL, err: File::NULL, pgroup: true)
      input.close
      writer_thread = Thread.new do
        writer.write(body)
      rescue IOError, SystemCallError
        nil
      ensure
        writer.close
      end

      status = wait_for(pid, timeout)
      terminate(pid) unless status
      status
    ensure
      input&.close unless input&.closed?
      writer&.close unless writer&.closed?
      writer_thread&.join
    end

    def self.wait_for(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        result = Process.wait2(pid, Process::WNOHANG)
        return result.last if result
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end

    def self.terminate(pid)
      signal_group("TERM", pid)
      sleep TERMINATION_GRACE
      signal_group("KILL", pid)
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end

    def self.signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    private_class_method :run, :wait_for, :terminate, :signal_group
  end
end
