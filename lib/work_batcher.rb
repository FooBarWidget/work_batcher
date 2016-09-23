# Copyright (c) 2016 Phusion B.V.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.


require 'thread'
require 'concurrent'
require 'concurrent/scheduled_task'

class WorkBatcher
  def initialize(options = {})
    @size_limit   = get_option(options, :size_limit)
    @time_limit   = get_option(options, :time_limit, 5)
    @deduplicate  = get_option(options, :deduplicate)
    @deduplicator = get_option(options, :deduplicator, method(:default_deduplicator))
    @executor     = get_option(options, :executor, Concurrent.global_io_executor)
    @processor    = get_option!(options, :processor)

    @mutex = Mutex.new
    if @deduplicate
      @queue = {}
    else
      @queue = []
    end
    @processed = 0
  end

  def shutdown
    task = @mutex.synchronize do
      @scheduled_processing_task
    end
    if task
      task.reschedule(0)
      task.wait!
    end
  end

  def add(work_object)
    @mutex.synchronize do
      if @deduplicate
        key = @deduplicator.call(work_object)
        @queue[key] = work_object
      else
        @queue << work_object
      end
      schedule_processing
    end
  end

  def add_multiple(work_objects)
    return if work_objects.empty?

    @mutex.synchronize do
      if @deduplicate
        work_objects.each do |work_object|
          key = @deduplicator.call(work_object)
          @queue[key] = work_object
        end
      else
        @queue.concat(work_objects)
      end
      schedule_processing
    end
  end

  def status
    result = {}
    @mutex.synchronize do
      if @scheduled_processing_task
        result[:scheduled_processing_time] = @scheduled_processing_time
      end
      result[:queue_count] = @queue.size
      result[:processed_count] = @processed
    end
    result
  end

  def inspect_queue
    @mutex.synchronize do
      if @deduplicate
        @queue.values.dup
      else
        @queue.dup
      end
    end
  end

private
  def schedule_processing
    if @scheduled_processing_task
      if @size_limit && @queue.size >= @size_limit
        @scheduled_processing_time = Time.now
        @scheduled_processing_task.reschedule(0)
      end
    else
      if @size_limit && @queue.size >= @size_limit
        @scheduled_processing_task = create_scheduled_processing_task(0)
      else
        @scheduled_processing_task = create_scheduled_processing_task(@time_limit)
      end
    end
  end

  def create_scheduled_processing_task(delay)
    @scheduled_processing_time = Time.now + delay
    args = [delay, executor: @executor]
    Concurrent::ScheduledTask.execute(*args) do
      handle_uncaught_exception do
        @mutex.synchronize do
          begin
            process_queue
          ensure
            @scheduled_processing_task = nil
            @scheduled_processing_time = nil
          end
        end
      end
    end
  end

  def process_queue
    if @deduplicate
      @processor.call(@queue.values)
    else
      @processor.call(@queue.dup)
    end
    @processed += @queue.size
    @queue.clear
  end

  def default_deduplicator(work_object)
    work_object
  end

  def handle_uncaught_exception
    begin
      yield
    rescue Exception => e
      STDERR.puts(
        "Uncaught exception in WorkBatcher: #{e} (#{e.class})\n" \
        "#{e.backtrace.join("\n")}")
    end
  end

  def get_option(options, key, default_value = nil)
    if options.key?(key)
      options[key]
    else
      default_value
    end
  end

  def get_option!(options, key)
    if options.key?(key)
      options[key]
    else
      raise ArgumentError, "Option required: #{key}"
    end
  end
end
