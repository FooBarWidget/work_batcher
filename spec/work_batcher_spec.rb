require_relative 'spec_helper'
require_relative '../lib/work_batcher'

describe WorkBatcher do
  before :each do
    @batches = Queue.new
  end

  after :each do
    if @work_batcher
      @work_batcher.shutdown
    end
  end

  def process(batch)
    @batches << batch
  end

  def int_wrapper_deduplicator(int_wrapper)
    int_wrapper.value
  end

  class IntWrapper
    attr_reader :value

    def initialize(value)
      @value = value
    end
  end

  describe '#add' do
    it 'increments the queue size' do
      @work_batcher = WorkBatcher.new(processor: method(:process))
      @work_batcher.add(1)
      expect(@work_batcher.status[:queue_count]).to eq(1)
      @work_batcher.add(1)
      expect(@work_batcher.status[:queue_count]).to eq(2)
    end

    it 'deduplicates if the :deduplicate option is set' do
      @work_batcher = WorkBatcher.new(processor: method(:process),
        deduplicate: true)
      @work_batcher.add(1)
      @work_batcher.add(1)
      @work_batcher.add(2)
      expect(@work_batcher.status[:queue_count]).to eq(2)
      expect(@work_batcher.inspect_queue).to eq([1, 2])
    end

    it 'deduplicates using the deduplicator' do
      @work_batcher = WorkBatcher.new(processor: method(:process),
        deduplicate: true,
        deduplicator: method(:int_wrapper_deduplicator))
      @work_batcher.add(IntWrapper.new(1))
      @work_batcher.add(IntWrapper.new(1))
      @work_batcher.add(IntWrapper.new(2))
      expect(@work_batcher.status[:queue_count]).to eq(2)

      queue = @work_batcher.inspect_queue
      expect(queue.size).to eq(2)
      expect(queue[0].value).to eq(1)
      expect(queue[1].value).to eq(2)
    end

    it 'schedules processing' do
      @work_batcher = WorkBatcher.new(processor: method(:process))
      @work_batcher.add(1)
      expect(@work_batcher.status[:scheduled_processing_time]).not_to be_nil
    end
  end

  describe '#add_multiple' do
    it 'increments the queue size' do
      @work_batcher = WorkBatcher.new(processor: method(:process))
      @work_batcher.add_multiple([1, 2])
      expect(@work_batcher.status[:queue_count]).to eq(2)
      @work_batcher.add_multiple([1, 2])
      expect(@work_batcher.status[:queue_count]).to eq(4)
    end

    it 'deduplicates if the :deduplicate option is set' do
      @work_batcher = WorkBatcher.new(processor: method(:process),
        deduplicate: true)
      @work_batcher.add_multiple([1])
      @work_batcher.add_multiple([1, 2])
      expect(@work_batcher.status[:queue_count]).to eq(2)
      expect(@work_batcher.inspect_queue).to eq([1, 2])
    end

    it 'deduplicates using the deduplicator' do
      @work_batcher = WorkBatcher.new(processor: method(:process),
        deduplicate: true,
        deduplicator: method(:int_wrapper_deduplicator))
      @work_batcher.add_multiple([IntWrapper.new(1)])
      @work_batcher.add_multiple([IntWrapper.new(1), IntWrapper.new(2)])
      expect(@work_batcher.status[:queue_count]).to eq(2)

      queue = @work_batcher.inspect_queue
      expect(queue.size).to eq(2)
      expect(queue[0].value).to eq(1)
      expect(queue[1].value).to eq(2)
    end

    it 'schedules processing' do
      @work_batcher = WorkBatcher.new(processor: method(:process))
      @work_batcher.add_multiple([1])
      expect(@work_batcher.status[:scheduled_processing_time]).not_to be_nil
    end
  end

  shared_examples_for 'processing' do
    it 'processes the batch when the time limit is reached' do
      @work_batcher = WorkBatcher.new(options.merge(
        processor: method(:process),
        time_limit: 0.1))
      add_multiple([1, 2, 3])
      start_time = Time.now
      batch = @batches.pop
      end_time = Time.now

      expect(batch).to eq([1, 2, 3])
      expect(end_time - start_time).to be_within(0.1).of(0.1)
    end

    describe 'if :size_limit is set' do
      it 'processes the batch when the size limit is reached even if the time limit is not yet reached' do
        @work_batcher = WorkBatcher.new(options.merge(
          processor: method(:process),
          time_limit: 1,
          size_limit: 3))
        add_multiple([1, 2, 3])
        start_time = Time.now
        batch = @batches.pop
        end_time = Time.now

        expect(batch).to eq([1, 2, 3])
        expect(end_time - start_time).to be_within(0.1).of(0)
      end

      it 'processes the batch when the time limit is reached even if the size limit is not yet reached' do
        @work_batcher = WorkBatcher.new(options.merge(
          processor: method(:process),
          time_limit: 0.1,
          size_limit: 3))
        add_multiple([1, 2])
        start_time = Time.now
        batch = @batches.pop
        end_time = Time.now

        expect(batch).to eq([1, 2])
        expect(end_time - start_time).to be_within(0.1).of(0.1)
      end
    end

    describe 'before processing the batch' do
      it 'reports on the scheduled batch processing time' do
        @work_batcher = WorkBatcher.new(options.merge(
          processor: method(:process),
          time_limit: 5))
        expect(@work_batcher.status[:scheduled_processing_time]).to be_nil
        add_multiple([1])
        expect(@work_batcher.status[:scheduled_processing_time]).to be_within(0.1).of(Time.now + 5)
      end
    end

    describe 'after processing the batch' do
      before :each do
        @work_batcher = WorkBatcher.new(options.merge(
          processor: method(:process),
          size_limit: 3))
        add_multiple([1, 2, 3])
        @batches.pop
      end

      specify 'the queue is empty' do
        expect(@work_batcher.status[:queue_count]).to eq(0)
      end

      specify 'the processed counter is incremented by the batch size' do
        expect(@work_batcher.status[:processed_count]).to eq(3)
      end

      it 'clears the scheduled batch processing time' do
        expect(@work_batcher.status[:scheduled_processing_time]).to be_nil
      end
    end
  end

  describe 'when deduplication is turned off' do
    let(:options) { {} }

    describe 'when using #add' do
      def add_multiple(work_objects)
        work_objects.each do |work_object|
          @work_batcher.add(work_object)
        end
      end

      include_examples 'processing'
    end

    describe 'when using #add_multiple' do
      def add_multiple(work_objects)
        @work_batcher.add_multiple(work_objects)
      end

      include_examples 'processing'
    end
  end

  describe 'when deduplication is turned on' do
    let(:options) { { deduplicate: true } }

    describe 'when using #add' do
      def add_multiple(work_objects)
        work_objects.each do |work_object|
          @work_batcher.add(work_object)
        end
      end

      include_examples 'processing'
    end

    describe 'when using #add_multiple' do
      def add_multiple(work_objects)
        @work_batcher.add_multiple(work_objects)
      end

      include_examples 'processing'
    end
  end
end
