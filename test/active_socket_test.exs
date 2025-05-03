defmodule ActiveSocketTest do
  use ExUnit.Case

  @seed :rand.uniform(1000)

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

  test "Socket connection (Active mode)", state do
    {:ok, pid} = Cand.Socket.start_link()
    assert :ok == Cand.Socket.connect(pid, {127,0,0,1}, state.port, [active: true])
    assert :ok == Cand.Socket.disconnect(pid)
    refute_receive :disconnect, 500
  end

  test "Open CAN bus (Active mode)", state do
    {:ok, pid} = Cand.Socket.start_link()
    assert :ok == Cand.Socket.connect(pid, {127,0,0,1}, state.port, [active: true])

    assert :ok == Cand.Protocol.open(pid, "vcan1")
    assert_receive :disconnect, 1000
    assert :ok == Cand.Socket.connect(pid, {127,0,0,1}, state.port, [active: true])
    assert :ok == Cand.Protocol.open(pid, "vcan0")

    assert :ok == Cand.Socket.disconnect(pid)
    refute_receive :disconnect, 500
  end

  test "Raw Mode CAN bus (Active mode)", state do
    {:ok, d1_pid} = Cand.Socket.start_link()

    assert :ok == Cand.Socket.connect(d1_pid, {127,0,0,1}, state.port, [active: true])

    assert :ok == Cand.Protocol.open(d1_pid, "vcan0")

    assert :ok == Cand.Protocol.raw_mode(d1_pid)

    # Wait for the socketcan to be ready
    Process.sleep(100)

    assert :ok == Cand.Protocol.send_frame(d1_pid, 291, <<103, 103, 103>>)
    refute_receive {:frame, {291, _timestamp, "ggg"}}, 500

    assert :ok == Cand.Socket.disconnect(d1_pid)
  end

  test "Raw Mode CAN bus between 2 devices (Active mode)", state do
    {:ok, d1_pid} = Cand.Socket.start_link()
    {:ok, d2_pid} = Cand.Socket.start_link()

    assert :ok == Cand.Socket.connect(d1_pid, {127,0,0,1}, state.port, [active: true])
    assert :ok == Cand.Socket.connect(d2_pid, {127,0,0,1}, state.port, [active: true])

    assert :ok == Cand.Protocol.open(d1_pid, "vcan0")
    assert :ok == Cand.Protocol.open(d2_pid, "vcan0")

    assert :ok == Cand.Protocol.raw_mode(d1_pid)
    assert :ok == Cand.Protocol.raw_mode(d2_pid)

    # Wait for the socketcan to be ready
    Process.sleep(100)

    assert :ok == Cand.Protocol.send_frame(d1_pid, 291, <<103, 103, 103>>)
    # Readed by d2_pid
    assert_receive {:frame, {291, _timestamp, "ggg"}}, 5000

    assert :ok == Cand.Protocol.send_frame(d2_pid, 0x103, <<123, 123, 123>>)
    # Readed by d1_pid
    assert_receive {:frame, {259, _timestamp, "{{{"}}, 500

    assert :ok == Cand.Socket.disconnect(d1_pid)
    assert :ok == Cand.Socket.disconnect(d2_pid)
  end

  test "BCM Mode CAN bus between 2 devices (Active mode)", state do
    {:ok, d1_pid} = Cand.Socket.start_link()
    {:ok, d2_pid} = Cand.Socket.start_link()

    assert :ok == Cand.Socket.connect(d1_pid, {127,0,0,1}, state.port, [active: true])
    assert :ok == Cand.Socket.connect(d2_pid, {127,0,0,1}, state.port, [active: true])

    assert :ok == Cand.Protocol.open(d1_pid, "vcan0")
    assert :ok == Cand.Protocol.open(d2_pid, "vcan0")

    assert :ok == Cand.Protocol.subscribe(d1_pid, 259)
    assert :ok == Cand.Protocol.send_frame(d2_pid, 0x103, <<123, 123, 123>>)

    # Readed by d1_pid
    assert_receive {:frame, {259, _timestamp, "{{{"}}, 500

    assert :ok == Cand.Protocol.add_cyclic_frame(d2_pid, 0x103, <<103, 103, 103>>, 0, 500000)

    # Readed by d1_pid
    assert_receive {:frame, {259, _timestamp, "ggg"}}, 500

    assert :ok == Cand.Protocol.delete_cyclic_frame(d2_pid, 0x103)

    refute_receive {:frame, {259, _timestamp, "ggg"}}, 500

    assert :ok == Cand.Socket.disconnect(d1_pid)
    assert :ok == Cand.Socket.disconnect(d2_pid)
  end
end
