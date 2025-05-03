defmodule Cand.Socket do
  @moduledoc """
    TCP socket handler for socketcand endpoint.

    This module provides functions for configuration, read/write CAN frames.
    `Cand.Socket` is implemented as a `__using__` macro so that you can put it in any module,
    you can initialize your Socket manually (see `test/socket_tests`) or by overwriting `configuration/1`,
    `cyclic_frames/1` and `subscriptions/1` to autoset the configuration, cyclic_frames and subscription items.
    It also helps you to handle new CAN frames and subscription events by overwriting `handle_frame/2` callback.

    The following example shows a module that takes its configuration from the environment (see `test/terraform_test.exs`):

    ```elixir
    defmodule MySocket do
      use Cand.Socket

      # Use the `init` function to configure your Socket.
      def init({parent_pid, 103} = _user_init_state, socket_pid) do
        %{parent_pid: parent_pid, socket_pid: socket_pid}
      end

      def configuration(_user_init_state), do: Application.get_env(:my_socket, :configuration, [])
      def cyclic_frames(_user_init_state), do: Application.get_env(:my_socket, :cyclic_frames, [])
      def subscriptions(_user_init_state), do: Application.get_env(:my_socket, :subscriptions, [])

      def handle_frame(new_frame, state) do
        send(state.parent_pid, {:handle_frame, new_frame})
        state
      end
    end
    ```
    Because it is small a GenServer, it accepts the same [options](https://hexdocs.pm/elixir/GenServer.html#module-how-to-supervise) for supervision
    to configure the child spec and passes them along to `GenServer`:
    ```elixir
    defmodule MyModule do
      use Cand.Socket, restart: :transient, shutdown: 10_000
    end
    ```
  """
  use GenServer

  require Logger

  defmodule State do
    @moduledoc """
      * last_cmds: It is a record of the last configuration commands that will be
                   resent in case of an unscheduled reconnection.
      * port: Socketcand deamon port, default => 29536.
      * host: Network Interface IP, default => {127, 0, 0, 1}.
      * socket: Socket PID.
      * controlling_process: Parent process.
      * status: nil, :connected, :disconnected.
    """
    defstruct last_cmds: [],
              port: 29536,
              host: {127, 0, 0, 1},
              socket: nil,
              socket_opts: [],
              controlling_process: nil,
              reconnect: false
  end

  @type config_options ::
          {:host, tuple()}
          | {:port, integer()}
          | {:interface, binary()}
          | {:mode, atom()}

  @doc """
  Optional callback that gets the Socket connection and CAN bus parameters.
  """
  @callback configuration(term()) :: config_options

  @callback cyclic_frames(term()) :: list()
  @callback subscriptions(term()) :: list()
  @callback handle_frame({integer(), binary(), binary()}, term()) :: term()
  @callback handle_disconnect(term()) :: term()
  @callback handle_error(term(), term()) :: term()


  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      use GenServer, Keyword.drop(opts, [:configuration])
      @behaviour Cand.Socket

      def start_link(user_initial_params \\ []) do
        GenServer.start_link(__MODULE__, user_initial_params, unquote(opts))
      end

      @impl true
      def init(user_initial_params) do
        send(self(), :init)
        {:ok, user_initial_params}
      end

      @impl true
      def handle_info(:init, user_initial_params) do
        # Socket Terraform
        {:ok, cs_pid} = Cand.Socket.start_link()

        configuration = apply(__MODULE__, :configuration, [user_initial_params])
        cyclic_frames = apply(__MODULE__, :cyclic_frames, [user_initial_params])
        subscriptions = apply(__MODULE__, :subscriptions, [user_initial_params])

        # configutation = list()
        set_socket_connection(cs_pid, configuration)
        set_socket_bus(cs_pid, configuration)

        # monitored_tiems = [subscription: 100.3, monitored_item: %MonitoredItem{}, ...]
        set_cyclic_frames(cs_pid, cyclic_frames)
        set_subscriptions(cs_pid, subscriptions)

        # User initialization.
        user_state = apply(__MODULE__, :init, [user_initial_params, cs_pid])

        {:noreply, user_state}
      end

      def handle_info({:frame, { _can_id, _timestamp, _frame} = new_frame}, state) do
        state = apply(__MODULE__, :handle_frame, [new_frame, state])
        {:noreply, state}
      end

      def handle_info(:disconnect, state) do
        state = apply(__MODULE__, :handle_disconnect, [state])
        {:noreply, state}
      end

      def handle_info({:error, error_data}, state) do
        state = apply(__MODULE__, :handle_error, [error_data, state])
        {:noreply, state}
      end

      @impl true
      def handle_frame(new_frame_data, state) do
        require Logger
        Logger.warning(
          "No handle_frame/3 clause in #{__MODULE__} provided for #{inspect(new_frame_data)}"
        )

        state
      end

      @impl true
      def handle_disconnect(state) do
        require Logger
        Logger.warning("No handle_disconnect/1 clause in #{__MODULE__} provided")
        state
      end

      @impl true
      def handle_error(error, state) do
        require Logger
        Logger.warning(
          "No handle_error/2 clause in #{__MODULE__} provided for #{inspect(error)}"
        )
        state
      end

      @impl true
      def configuration(_user_init_state), do: []

      @impl true
      def cyclic_frames(_user_init_state), do: []

      @impl true
      def subscriptions(_user_init_state), do: []

      defp set_socket_connection(_cs_pid, nil), do: :ok

      defp set_socket_connection(cs_pid, configuration) do
        with host <- Keyword.get(configuration, :host, {127, 0, 0, 1}),
             true <- is_tuple(host),
             {:ok, ip_host} <- ip_to_tuple(host),
             port <- Keyword.get(configuration, :port, 29536),
             true <- is_integer(port) do
          Cand.Socket.connect(cs_pid, ip_host, port, [active: true])
        else
          _ ->
            require Logger

            Logger.warning(
              "Invalid Socket Connection params: #{inspect(configuration)} provided by #{
                __MODULE__
              }"
            )
        end
      end

      defp set_socket_bus(_cs_pid, nil), do: :ok

      defp set_socket_bus(cs_pid, configuration) do
        with interface <- Keyword.get(configuration, :interface, nil),
             true <- is_binary(interface),
             :ok <- Cand.Protocol.open(cs_pid, interface),
             mode <- Keyword.get(configuration, :mode, :raw_mode),
             true <- mode in [:bcm_mode, :raw_mode, :control_mode, :iso_tp_mode],
             :ok <- apply(Cand.Protocol, mode, [cs_pid]) do
          :ok
        else
          _ ->
            require Logger

            Logger.warning(
              "Invalid Socket Bus params: #{inspect(configuration)} provided by #{__MODULE__}"
            )
        end
      end

      defp set_cyclic_frames(socket, cyclic_frames) do
        Enum.each(cyclic_frames, fn cyclic_frame_data ->
          apply(Cand.Protocol, :add_cyclic_frame, [socket] ++ cyclic_frame_data)
        end)
      end

      defp set_subscriptions(socket, subscriptions) do
        Enum.each(subscriptions, fn subscription_data ->
          apply(Cand.Protocol, :subscribe, [socket] ++ subscription_data)
        end)
      end

      defguardp is_ipv4_octet(v) when v >= 0 and v <= 255

      defp ip_to_tuple({a, b, c, d} = ipa)
           when is_ipv4_octet(a) and is_ipv4_octet(b) and is_ipv4_octet(c) and is_ipv4_octet(d),
           do: {:ok, ipa}

      defp ip_to_tuple(ipa) when is_binary(ipa) do
        ipa_charlist = to_charlist(ipa)

        case :inet.parse_address(ipa_charlist) do
          {:ok, addr} -> {:ok, addr}
          {:error, :einval} -> {:error, "Invalid IP address: #{ipa}"}
        end
      end

      defp ip_to_tuple(ipa), do: {:error, "Invalid IP address: #{inspect(ipa)}"}

      defoverridable start_link: 0,
                     start_link: 1,
                     configuration: 1,
                     cyclic_frames: 1,
                     subscriptions: 1,
                     handle_frame: 2,
                     handle_error: 2,
                     handle_disconnect: 1
    end
  end

  def init(state), do: {:ok, state}

  def start_link do
    GenServer.start_link(__MODULE__, %State{controlling_process: self()})
  end

  def connect(pid, host, port, opts \\ [active: false]) do
    GenServer.call(pid, {:connect, host, port, opts})
  end

  def disconnect(pid) do
    GenServer.call(pid, :disconnect)
  end

  def send(pid, cmd, timeout \\ :infinity) do
    GenServer.call(pid, {:send, cmd, timeout})
  end

  def receive(pid, timeout \\ :infinity) do
    GenServer.call(pid, {:receive, timeout})
  end

  def handle_call({:connect, host, port, [active: false] = opts}, _from_, state) do
    with  {:ok, socket} <- :gen_tcp.connect(host, port, opts),
          {:ok, message} <- :gen_tcp.recv(socket, 0),
          response <- parse_message(message) do
      {:reply, response, %{state | socket: socket, host: host, port: port, socket_opts: opts, reconnect: true}}
    else
      error_reason ->
        {:reply, error_reason, state}
    end
  end

  def handle_call({:connect, host, port, opts}, _from_, state) do
    with {:ok, socket} <- :gen_tcp.connect(host, port, opts) do
      {:reply, :ok, %{state | socket: socket, host: host, port: port, socket_opts: opts}}
    else
      error_reason ->
        {:reply, error_reason, state}
    end
  end

  def handle_call(_call, _from, %{socket: nil} = state) do
    Logger.warning("(#{__MODULE__}) There is no available socket. #{inspect(state)}")
    {:reply, {:error, :einval}, %{state | socket: nil}}
  end

  # wait for response
  def handle_call({:send, cmd, timeout}, _from, %{socket_opts: [active: false]} = state) do
    Logger.debug("(#{__MODULE__}) Sending: #{cmd}. #{inspect(state)}")
    with  :ok <- :gen_tcp.send(state.socket, cmd),
          new_cmds <- add_new_cmd(cmd, state.last_cmds),
          {:ok, message} <- receive_reponse(cmd, state.socket, timeout),
          response <- parse_messages(message) do
      {:reply, response, %{state | last_cmds: new_cmds}}
    else
      error_reason ->
        {:reply, error_reason, %{state | socket: nil}}
    end
  end

  def handle_call({:send, cmd, _timeout}, _from, %{last_cmds: cmds} = state) do
    Logger.debug("(#{__MODULE__}) Sending: #{cmd}. #{inspect(state)}")
    with  :ok <- :gen_tcp.send(state.socket, cmd),
          new_cmds <- add_new_cmd(cmd, cmds) do
      {:reply, :ok, %{state | last_cmds: new_cmds}}
    else
      error_reason ->
        {:reply, error_reason, %{state | socket: nil}}
    end
  end

  def handle_call({:receive, timeout}, _from, %{socket_opts: [active: false]} = state) do
    Logger.debug("(#{__MODULE__}) Reading. #{inspect(state)}")
    with  {:ok, message} <- :gen_tcp.recv(state.socket, 0, timeout),
          response <- parse_messages(message) do
      {:reply, response, state}
    else
      error_reason ->
        {:reply, error_reason, %{state | socket: nil}}
    end
  end

  def handle_call({:receive, _timeout}, _from, state) do
    Logger.warning("(#{__MODULE__}) The socket is configured as passive. #{inspect(state)}")
    {:reply, {:error, :einval}, state}
  end

  def handle_call(:disconnect, _from, %{socket: socket} = state) do
    with  :ok <- :gen_tcp.close(socket) do
      {:reply, :ok, %{state | reconnect: false}}
    else
      error_reason ->
        {:reply, error_reason, %{state | socket: nil}}
    end
  end

  # Active Mode
  def handle_info({:tcp, _port, ~c"< hi >"}, state) do
    Logger.info("(#{__MODULE__}) Connected. #{inspect(state)}")
    {:noreply, %{state | reconnect: true}}
  end

  def handle_info({:tcp, _port, ~c"< ok >"}, state) do
    Logger.debug("(#{__MODULE__}) OK. #{inspect(state)}")
    {:noreply, state}
  end

  def handle_info({:tcp, _port, ~c"< echo >"}, state) do
    Logger.debug("(#{__MODULE__}) Echo received. #{inspect(state)}")
    {:noreply, state}
  end

  def handle_info({:tcp, _port, message}, %{controlling_process: p_pid} = state) do
    message
    |> parse_messages
    |> Enum.map(fn message ->
      dispatch(message, p_pid)
    end)

    {:noreply, state}
  end

  def handle_info({:tcp_closed, _port}, %{reconnect: false} = state) do
    Logger.info("(#{__MODULE__}) Expected disconnection. #{inspect(state)}")
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _port}, state) do
    Logger.warning("(#{__MODULE__}) Unexpected disconnection. Reconnect...")
    Kernel.send(state.controlling_process, :disconnect)
    {:noreply, state}
  end

  defp add_new_cmd("< send " <> _payload, last_cmds), do: last_cmds
  defp add_new_cmd("< sendpdu " <> _payload, last_cmds), do: last_cmds
  defp add_new_cmd(cmd, last_cmds), do: Enum.uniq(last_cmds ++ [cmd])

  defp receive_reponse("< send " <> _payload, _socket, _timeout), do: {:ok, ~c"< ok >"}
  defp receive_reponse("< sendpdu " <> _payload, _socket, _timeout), do: {:ok, ~c"< ok >"}
  defp receive_reponse(_cmd, socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)

  defp parse_messages(messages) do
    messages
    |> List.to_string()
    |> String.split("><")
    |> Enum.map(fn frame ->
      frame
      |> String.trim("<")
      |> String.trim(">")
      |> String.trim()
      |> parse_message
    end)
  end

  defp parse_message(message) when is_list(message) do
    message
    |> List.to_string()
    |> String.trim("<")
    |> String.trim(">")
    |> String.trim()
    |> parse_message()
  end
  defp parse_message("frame " <> payload) do
    with [can_id_str, timestamp, can_frame] <- String.split(payload, " ", parts: 3),
         can_frame_bin <- str_to_bin_frame(can_frame),
         can_id_int <- String.to_integer(can_id_str, 16) do
      {:frame, {can_id_int, timestamp, can_frame_bin}}
    else
      error_reason ->
        {:error, error_reason}
    end
  end
  defp parse_message("ok"), do: :ok
  defp parse_message("hi"), do: :hi
  defp parse_message("echo"), do: :ok
  defp parse_message("error " <> message), do: {:error, message}
  defp parse_message(message), do: {:error, message}

  defp str_to_bin_frame(can_frame) do
    can_frame = String.replace(can_frame, " ", "")
    for <<byte::binary-2 <- can_frame>>,reduce: <<>> do
      acc -> acc <> <<String.to_integer(byte, 16)>>
    end
  end

  defp dispatch({:frame, _frame_data} = message, p_pid), do: Kernel.send(p_pid, message)
  defp dispatch({:error, _error_msg} = message, p_pid), do: Kernel.send(p_pid, message)
  defp dispatch(message, _p_pid), do: Logger.debug("(#{__MODULE__}) #{inspect(message)}")
end
