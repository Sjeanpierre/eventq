module EventQ
  module RabbitMq
    class QueueWorker

      attr_accessor :is_running

      def initialize
        @threads = []
        @is_running = false

        @retry_exceeded_block = nil
      end

      def start(queue, options = {}, &block)

        configure(queue, options)

        puts '[QUEUE_WORKER] Listening for messages.'

        raise 'Worker is already running.' if running?

        @is_running = true
        @threads = []

        #loop through each thread count
        @thread_count.times do
          thr = Thread.new do

            client = QueueClient.new
            manager = QueueManager.new

            #begin the queue loop for this thread
            while true do

              #check if the worker is still allowed to run and break out of thread loop if not
              if !@is_running
                break
              end

              channel = client.get_channel

              #get the queue
              q = manager.get_queue(channel, queue)
              retry_exchange = manager.get_retry_exchange(channel, queue)

              received = false
              error = false
              abort = false

              begin
                delivery_info, properties, payload = q.pop(:manual_ack => true, :block => true)

                #check that message was received
                if payload != nil

                  message = Oj.load(payload)

                  puts "[QUEUE_WORKER] Message received. Retry Attempts: #{message.retry_attempts}"
                  puts properties

                  message_args = EventQ::MessageArgs.new(message.type, message.retry_attempts)

                  #begin worker block for queue message
                  begin
                    block.call(message.content, message_args)

                    if message_args.abort == true
                      abort = true
                      puts '[QUEUE_WORKER] Message aborted.'
                    else
                      #accept the message as processed
                      channel.acknowledge(delivery_info.delivery_tag, false)
                      puts '[QUEUE_WORKER] Message acknowledged.'
                      received = true
                    end

                  rescue => e
                    puts '[QUEUE_WORKER] An unhandled error happened attempting to process a queue message.'
                    puts "Error: #{e}"

                    error = true

                  end

                  if error || abort
                    reject_message(channel, message, delivery_info, retry_exchange, queue)
                  end

                end

              rescue Timeout::Error
                puts 'Timeout occured attempting to pop a message from the queue.'
              end

              channel.close

              #check if any message was received
              if !received && !error
                puts "[QUEUE_WORKER] No message received. Sleeping for #{@sleep} seconds"
                #no message received so sleep before attempting to pop another message from the queue
                sleep(@sleep)
              end

            end

          end
          @threads.push(thr)

        end

        if options.key?(:wait) && options[:wait] == true
          @threads.each { |thr| thr.join }
        end

        return true

      end

      def stop
        @is_running = false
        @threads.each { |thr| thr.join }
        return true
      end

      def on_retry_exceeded(&block)
        @retry_exceeded_block = block
        return nil
      end

      def running?
        return @is_running
      end

      private

      def reject_message(channel, message, delivery_info, retry_exchange, queue)
        #reject the message to remove from queue
        channel.reject(delivery_info.delivery_tag, false)

        puts '[QUEUE_WORKER] Message rejected.'

        #check if the message is allowed to be retried
        if queue.allow_retry

          puts '[QUEUE_WORKER] Checking retry attempts...'

          if message.retry_attempts < queue.max_retry_attempts
            puts'[QUEUE_WORKER] Incrementing retry attempts count.'
            message.retry_attempts += 1
            puts '[QUEUE_WORKER] Sending message for retry.'
            retry_exchange.publish(Oj.dump(message))
            puts '[QUEUE_WORKER] Published message to retry exchange.'
          elsif @retry_exceeded_block != nil
            puts '[QUEUE_WORKER] Executing retry exceeded block.'
            @retry_exceeded_block.call(message)
          else
            puts '[QUEUE_WORKER] No retry exceeded block specified.'
          end

        end

        return true

      end

      def configure(queue, options = {})

        @queue = queue

        #default thread count
        @thread_count = 5
        if options.key?(:thread_count)
          @thread_count = options[:thread_count]
        end

        #default sleep time in seconds
        @sleep = 15
        if options.key?(:sleep)
          @sleep = options[:sleep]
        end

        return true

      end

    end
  end
end

