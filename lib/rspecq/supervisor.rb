module RSpecQ
  # A Supervisor is responsible for starting and monitoring the worker
  # process for a given build.
  #
  # It handles signals and ensures that the worker is gracefully
  # terminated when needed.
  #
  # The worker process itself cannot handle signals in a safe manner,
  # since it executes application and rspec code. Gem's like mysql2,
  # activerecord, etc, can swallow signals, wrap them in other exceptions,
  # etc, leading to unpredictable behavior.
  #
  # The Supervisor does two things:
  # 1) It starts the worker process
  # 2) It handles signals and gracefully terminates the worker
  #     by first signaling graceful termination (via an io pipe), and then after a timeout, SIGKILL.
  #
  # The supervisor itself triggers the worker shutdown and exits
  # with the same code as the worker.
  #
  # The io pipe trick because we do not trust the worker to handle signals
  # properly. The worker listens on the pipe and when it is closed, it
  # gracefully shuts down.
  #
  class Supervisor
    # How long to wait for the worker to gracefully shutdown before sending SIGKILL
    attr_reader :graceful_shutdown_timeout

    # The signal that triggers that triggers graceful shutdown
    # Typically TERM
    attr_reader :graceful_shutdown_signal

    def initialize(graceful_shutdown_timeout: nil, graceful_shutdown_signal: nil, worker_opts: {})
      @shutdown = false
      @shutdown_initiated_at = nil

      @graceful_shutdown_signal = graceful_shutdown_signal
      @graceful_shutdown_timeout = graceful_shutdown_timeout
      @graceful_shutdown_sent = false
      @sigkill_shutdown_sent = false

      @worker_opts = worker_opts

      @worker_io_rd, @supervisor_io_wr = IO.pipe
    end

    def worker
      @worker ||= Worker.new(
        shutdown_pipe: @worker_io_rd,
        **@worker_opts
      )
    end

    def register_signal_handlers
      Signal.trap(graceful_shutdown_signal) { initiate_shutdown(graceful_shutdown_signal) }
      Signal.trap("INT") { initiate_shutdown("INT") }
    end

    def initiate_shutdown(signal)
      @shutdown = true
      @shutdown_initiated_at = Time.now

      puts "Supervisor received signal #{signal}, initiating shutdown..."
    end

    def shutdown?
      @shutdown
    end

    def graceful_shutdown_sent?
      @graceful_shutdown_sent
    end

    def sigkill_shutdown_sent?
      @sigkill_shutdown_sent
    end

    def graceful_shutdown_timeout_reached?
      @graceful_shutdown_sent && (Time.now - @shutdown_initiated_at) > graceful_shutdown_timeout
    end

    attr_reader :supervisor_io_wr

    def run
      register_signal_handlers

      wpid = Process.fork do
        # Child process (worker)
        @supervisor_io_wr.close
        worker.work
      end
      # Parent process (supervisor)
      @worker_io_rd.close
      worker_id = worker.worker_id

      # Monitor the worker process
      loop do
        if shutdown? && !graceful_shutdown_sent?
          warn "Shutting down worker gracefully via io.pipe (#{worker_id}), timeout=#{graceful_shutdown_timeout}s..."
          @supervisor_io_wr.close unless @supervisor_io_wr.closed?

          @graceful_shutdown_sent = true
          @shutdown = false # Prevent entering this block again
        end

        if graceful_shutdown_timeout_reached? && !sigkill_shutdown_sent?
          warn "Graceful shutdown timeout reached, sending SIGKILL to worker (#{worker_id})..."
          Process.kill("KILL", wpid)

          @sigkill_shutdown_sent = true
        end

        _, status = Process.wait2(wpid, Process::WNOHANG) # Non-blocking check

        if status
          puts "Worker sub-process (#{worker_id}) exited, #{status}" if !status.success?

          # Clean up worker state in the queue if needed
          queue = Queue.new(worker.build_id, worker.worker_id, worker.redis_opts)
          not_graceful = queue.remove_worker(worker_id)
          if not_graceful
            warn "Worker (#{worker_id}) was removed while having a reserved job"
          end

          exit status.exitstatus || -2
        end

        sleep 0.5
      end
    end
  end
end
