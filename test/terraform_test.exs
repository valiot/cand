defmodule SocketTerraformTest do
  use ExUnit.Case

  @seed :rand.uniform(1000)

  @socket_configuration [
    host: {127, 0, 0 , 1},
    port: 28600 + @seed,
    interface: "vcan0",
    mode: :bcm_mode
  ]

  @cyclic_frames [
    [0x103, <<103, 103, 103>>, 0, 500000]
  ]

  @subscriptions [
    [291]
  ]

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

  setup_all do
    socketcand_exec = System.find_executable("socketcand")
    port = 28600 + @seed
    socketcand_params = ["-v", "-ivcan0", "-p#{port}", "-llo", "-n", "-d"]
    muontrap_params = [
      stderr_to_stdout: true,
      log_output: :debug,
      log_prefix: "(#{__MODULE__}) "
    ]

    {:ok, m_pid} = MuonTrap.Daemon.start_link(socketcand_exec, socketcand_params, muontrap_params)

    Process.sleep(500)

    {:ok, %{port: port, m_pid: m_pid}}
  end

  test "Socket terraform", state do
    Application.put_env(:my_socket, :configuration, @socket_configuration)
    Application.put_env(:my_socket, :cyclic_frames, @cyclic_frames)
    Application.put_env(:my_socket, :subscriptions, @subscriptions)

    {:ok, d1_pid} = Cand.Socket.start_link()

    assert :ok == Cand.Socket.connect(d1_pid, {127,0,0,1}, state.port, [active: true])

    assert :ok == Cand.Protocol.open(d1_pid, "vcan0")

    assert :ok == Cand.Protocol.subscribe(d1_pid, 0x103)
    refute_receive {:frame, {0x103, _timestamp, "ggg"}}, 500

    {:ok, _c_pid} = MySocket.start_link({self(), 103})
    assert_receive {:frame, {0x103, _timestamp, "ggg"}}, 500

    Process.sleep(100)

    assert :ok == Cand.Protocol.send_frame(d1_pid, 291, <<103, 103, 103>>)
    assert_receive {:handle_frame, {291, _timestamp, "ggg"}}, 500
  end

end
