defmodule GenStage do
  @moduledoc """
  Stages are computation steps that send and/or receive data
  from other stages.

  When a stage sends data, it acts as a producer. When it receives
  data, it acts as a consumer. Stages may take both producer and
  consumer roles at once.

  ## Stage types

  Besides taking both producer and consumer roles, a stage may be
  called "source" if it only produces items or called "sink" if it
  only consumes items.

  For example, imagine the stages below where A sends data to B
  that sends data to C:

      [A] -> [B] -> [C]

  we conclude that:

    * A is only a producer (and therefore a source)
    * B is both producer and consumer
    * C is only consumer (and therefore a sink)

  As we will see in the upcoming Examples section, we must
  specify the type of the stage when we implement each of them.

  To start the flow of events, we subscribe consumers to
  producers. Once the communication channel between them is
  established, consumers will ask the producers for events.
  We typically say the consumer is sending demand upstream.
  Once demand arrives, the producer will emit items, never
  emitting more items than the consumer asked for. This provides
  a back-pressure mechanism.

  Typically, a consumer may subscribe only to a single producer
  and establish a one-to-one relationship. GenBroker lifts this
  restriction by allowing connecting M producers to N consumers
  and managing events with different strategies.

  ## Example

  Let's define the simple pipeline below:

      [A] -> [B] -> [C]

  where A is a producer that will emit items starting from 0,
  B is a producer-consumer that will receive those items and
  multiply them by a given number and C will receive those events
  and print them to the terminal.

  Let's start with A. Since A is a producer, its main
  responsibility is to receive demand and generate events.
  Those events may be in memory or an external queue system.
  For simplicity, let's use a simple counter starting from 0:

      defmodule A do
        use GenStage

        def init(counter) do
          {:producer, counter}
        end

        def handle_demand(demand, counter) when demand > 0 do
          # If the counter is 3 and we ask for 2 items,
          # we will emit 3 and 4, and set the state to 5.
          events = Enum.to_list(counter..counter+demand-1)
          {:noreply, events, counter + demand}
        end
      end

  B is a producer-consumer. This means it does not explicitly
  handle the demand, because the demand is always forwarded to
  its producer. Instead B receives events and generate events
  from the events themselves. In our case, B will receive events
  and multiply them by a given number:

      defmodule B do
        use GenStage

        def init(number) do
          {:producer_consumer, number}
        end

        def handle_event(event, number) do
          {:noreply, [event * number], state}
        end
      end

  C will finally receive those events and print them to the
  terminal:

      defmodule C do
        use GenStage

        def init(:ok) do
          {:consumer, :the_state_does_not_matter}
        end

        def handle_event(event, state) do
          # Inspect the event.
          IO.inspect(event)

          # We are a consumer, so we would never emit items.
          {:noreply, [], state}
        end
      end

  Now we can start and connect them:

      {:ok, a} = GenStage.start_link(A, 0)   # starting from zero
      {:ok, b} = GenStage.start_link(B, 2)   # multiply by 2
      {:ok, c} = GenStage.start_link(C, :ok) # state does not matter

      GenStage.sync_subscribe(c, to: b)
      GenStage.sync_subscribe(b, to: a)

  After you subscribe all of them, demand will start flowing
  upstream and events downstream. Because C is the one effectively
  generating the demand, we usually set the `:max_demand` and
  `:min_demand` options. The `:max_demand` specifies the maximum
  amount of events it must be in flow, the `:min_demand` specifies
  the minimum. For example, if `:max_demand` is 100 and `:min_demand`
  is 50 (the default values), the consumer will ask for 100 events
  initially and ask for more only after it receives at least 50.

  ## Streams

  After exploring the example above, you may be thinking that's
  a lot of code for something that could be expressed with streams.
  For example:

      Stream.iterate(0, fn i -> i + 1 end)
      |> Stream.map(fn i -> i * 2 end)
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()

  The example above would print the same values as our stages with
  the difference the stream above is not leveraging concurrency.
  We can, however, break the stream into multiple stages too:

      Stream.iterate(0, fn i -> i + 1 end)
      |> Stream.async_stage()
      |> Stream.map(fn i -> i * 2 end)
      |> Stream.async_stage()
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()

  Now each step runs into its own stage, using the same primitives
  as we have discussed above. While using streams may be helpful in
  many occasions, there are many reasons why someone would use
  GenStage, some being:

    * Stages provide a more structured approach by breaking into
      stage into a separate module
    * Stages provide all callbacks necessary for process management
      (init, terminate, etc)
    * Stages can be hot-code upgraded
    * Stages can be supervised individually

  ## Callbacks

  `GenStage` is implemented on top of a `GenServer` with two additions.
  Besides exposing all of the `GenServer` callbacks, it also provides
  `handle_demand/2` to be implemented by producers and `handle_event/3`
  to be implemented by consumers, as shown above. Futhermore, all the
  callback responses have been modified to be potentially emit events.
  See the callbacks documentation for more information.

  By adding `use GenStage` to your module, Elixir will automatically
  define all callbacks for you, leaving it up to you to implement the
  ones you want to customize.

  Although this module exposes functions similar to the ones found in
  the `GenServer` API, like `call/3` and `cast/2`, developers can also
  rely directly on the GenServer API such as `GenServer.multi_call/4`
  and `GenServer.abcast/3` if they wish to.

  ## Name Registration

  `GenStage` is bound to the same name registration rules as a `GenServer`.
  Read more about it in the `GenServer` docs.

  ## Message-protocol overview

  This section will describe the message-protocol implemented
  by stages. By documenting these messages, we will allow
  developers to provide their own stage implementations.

  ### Back-pressure

  When data is sent between stages, it is done by a message
  protocol that provides back-pressure. The first step is
  for the consumer to subscribe to the producer. Each
  subscription has a unique reference. Once a subscription is
  done, many connections may be established.

  Once a connection is established, the consumer may ask the
  producer for messages for the given subscription-connection
  pair. The consumer may demand more items whenever it wants
  to. A consumer must never receive more data than it has asked
  for from any given producer stage.

  ### Producer messages

  TODO.

  ### Consumer messages

  TODO.
  """

  # TODO: Make handle_demand and handle_event optional

  @typedoc "The supported stage types."
  @type type :: :producer | :consumer | :producer_consumer

  @typedoc "The supported init options"
  @type options :: []

  @doc """
  Invoked when the server is started.

  `start_link/3` (or `start/3`) will block until it returns. `args`
  is the argument term (second argument) passed to `start_link/3`.

  In case of successful start, this callback must return a tuple
  where the first element is the stage type, which is either
  a `:producer`, `:consumer` or `:producer_consumer` if it is
  taking both roles.

  For example:

      def init(args) do
        {:producer, some_state}
      end

  The returned tuple may also contain 3 or 4 elements. The third
  element may be a timeout value as integer, the `:hibernate` atom
  or a set of options defined below.

  Returning `:ignore` will cause `start_link/3` to return `:ignore`
  and the process will exit normally without entering the loop or
  calling `terminate/2`.

  Returning `{:stop, reason}` will cause `start_link/3` to return
  `{:error, reason}` and the process to exit with reason `reason`
  without entering the loop or calling `terminate/2`.

  ## Options

  This callback accepts a different set of options depending on the
  stage type.

  ### :producer options

  No options are supported for this type.

  ### :consumer options

    * `:max_demand` - the maximum demand desired to send upstream.
      Those options are default values

  """
  @callback init(args :: term) ::
    {type, state} |
    {type, state, options} |
    {type, state, timeout | :hibernate} |
    {type, state, timeout | :hibernate, options} |
    :ignore |
    {:stop, reason :: any} when state: any
end