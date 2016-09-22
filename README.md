# Small library for batching work

Many types of work can be performed more efficiently when performed in batches rather than individually. For example, performing a single coarse-grained HTTP API call with multiple inputs is often faster than performing multiple smaller HTTP API calls because it reduces the number of network roundtrips. Enter WorkBatcher: a generic library for performing any kind of work in batches.

WorkBatcher works as follows. First you tell WorkBatcher whether you want to batch by time or by size (or both). Then you pass work objects to WorkBatcher, which WorkBatcher adds to an internal store (the batch). When either the batch size limit or the time limit has been reached, WorkBatcher calls a user-specified callback (passing it the batch) to perform the actual processing of the batch.

Below is a small example that batches by time. Given a WorkBatcher object, call the `#add` method to add work objects. When the given time limit is reached (2 seconds in this example), it will call the `process_batch` lambda with all work objects that have been batched during that 2 seconds interval.

~~~ruby
process_batch = lambda do |batch|
  # Warning! Code is executed in a different thread!
  puts "Processing batch: #{batch.inspect}"
end

wb = WorkBatcher.new(processor: process_batch, time_limit: 2)
wb.add('work object 1')
wb.add('work object 2')
sleep 3
# => Processing batch: ["work object 1", "work object 2"]

wb.add('work object 1')
wb.add('work object 4')
sleep 3
# => Processing batch: ["work object 1", "work object 4"]

# Don't forget to cleanup.
wb.shutdown
~~~

**Table of contents***

 * [Installation](#installation)
 * [Features](#features)
 * [Not a background job system](#not-a-background-job-system)
 * [API](#api)
   - [Constructor options](#constructor-options)
   - [Adding work objects](#adding-work-objects)
   - [Deduplicating work objects](#deduplicating-work-objects)
   - [Concurrency notes](#concurrency-notes)

--------

## Installation

    gem install work_batcher

## Features

 * Lightweight library, not a background job system with daemon.
 * You can configure it to process the batch either after a time limit, or after a certain number of items have been queued, or both.
 * Able to avoid double work by [deduplicating work objects](#deduplicating work objects].
 * Introspectable: you can query its processing status at any time.
 * Thread-safe.
 * Uses threads under the hood.
 * The only dependency is concurrent-ruby. Unlike e.g. [http://www.rubydoc.info/gems/task_batcher/0.1.0](task_batcher), this library does not depend on EventMachine.

## Not a background job system

This library is *not* a background job system such as Sidekiq, BackgrounDRb or Resque. Those libraries are daemons that you run in the background for processing work. This library is for *batching* work. But you could combine this library with a background job system in order to add batching capabilities.

## API

### Constructor options

The constructor supports the following options.

Required:

 * `:processor` (callable) -- will be called when WorkBatcher determines that it is time to process a batch. The callable will receive exactly one argument: an array of batched objects. The callable is called in a background thread; see [Concurrency notes](#concurrency-notes).

Optional:

 * `:size_limit` (Integer) -- if the internal queue reaches this given size, then the current batch will be processed. Defaults to nil, meaning that WorkBatcher does not check the size.
 * `:time_limit` (Float) -- if this much time has passed since the first time a work object has been placed in an empty queue, then the current batch will be processed. The unit is seconds, and may be a floating point number. Defaults to 5.
 * `:deduplicate` (Boolean) -- whether to [deduplicate work objects](#deduplicating-work-objects) or not. Defaults to false.
 * `:deduplicator` (callable) -- see [Deduplicating work objects](#deduplicating-work-objects) for more information.
 * `:executor` -- a [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby) executor or thread pool object to perform background work in. Defaults to `Concurrent.global_io_executor`.

Note that `:size_limit` and `:time_limit` can be combined. If either condition is reached then the batch will be processed.

### Adding work objects

Add work objects with either the `#add` method (for adding a single object) or the `#add_multiple` method (for adding multiple objects). If you have multiple work objects, then it is more efficient to call `#add_multiple` once instead of calling `#add` many times.

    work_batcher.add(work_object)
    work_batcher.add_multiple([work_object1, work_object2])

A work object can be anything. Work_batcher does not do anything with the objects themselves; they are simply passed to the processor callable (although they may be [deduplicated](#deduplicating-work-objects) first).

### Deduplicating work objects

In some use cases it is desirable to deduplicate added work objects. Suppose that you are writing a social network in which each user can upload an avatar. You want to pass recently uploaded avatars to an image compressor service, and in order to reduce network roundtrips you want to do this in batches. What happens if you have _just_ added an avatar to a batch, but before the batch is sent out to the compressor service, the user uploads a new avatar? You want to replace that user's avatar in the batch with his/her latest one.

Enter deduplication. It starts by setting the `:deduplicate` option to true. When you add a work object, WorkBatcher will look in the batch for any objects that look like duplicates and remove them. By default, two work objects are considered equal if `#eql?` is true and (at the same time) their `#hash` are equal. This is because deduplication is internally implemented using a Hash.

The criteria for what is considered "duplicate" is configurable through the `:deduplicator` option. This option is to be set to a callable, which accepts a work object and which outputs a key object. Two work objects are considered duplicates if their key objects are the same (according to `#eql?` and `#hash`).

Here is an example on how to deduplicate avatars:

~~~ruby
deduplicator = lambda do |avatar|
  # We consider two avatars to be duplicates if they are from the
  # same user, so we return the user ID here.
  avatar.user_id
end

processor = lambda do |avatars|
  send_avatars_to_compressor_service(avatars)
end

wb = WorkBatcher.new(
  deduplicate: true,
  deduplicator: deduplicator,
  processor: processor)

while !$quitting
  avatar = receive_next_avatar
  wb.add(avatar1)
end
~~~

Deduplication is disabled by default.

### Concurrency notes

WorkBatcher uses threads internally. The processor callback is called in a background thread, so care should be taken to ensure that your processor callback is thread-safe.

When using Rails, if your processor callback does anything with ActiveRecord then you must ensure that the processor callback releases the ActiveRecord thread-local connection, otherwise you will exhaust the ActiveRecord connection pool. Here is an example:

~~~ruby
processor = lambda do |batch|
  begin
    ...
  ensure
    ActiveRecord::Base.connection_pool.release_connection
  end
end
~~~
