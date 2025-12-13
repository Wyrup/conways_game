defmodule ConwaysGame do
  @moduledoc """
  Conway's Game of Life - Distributed Implementation
  Each cell is a separate Elixir process across multiple BEAM VMs.
  """
end

defmodule ConwaysGame.Cell do
  @moduledoc "GenServer process for a single cell"
  use GenServer

  def start_link(x, y, alive? \\ false) do
    GenServer.start_link(__MODULE__, {x, y, alive?})
  end

  def set_neighbors(pid, neighbors), do: GenServer.cast(pid, {:set_neighbors, neighbors})
  def compute_next(pid), do: GenServer.call(pid, :compute_next)
  def apply_next(pid), do: GenServer.cast(pid, :apply_next)
  def is_alive?(pid), do: GenServer.call(pid, :is_alive)
  def set_state(pid, alive?), do: GenServer.cast(pid, {:set_state, alive?})

  @impl true
  def init({x, y, alive?}) do
    {:ok, %{position: {x, y}, alive: alive?, neighbors: [], next_state: alive?}}
  end

  @impl true
  def handle_call(:is_alive, _from, state), do: {:reply, state.alive, state}

  @impl true
  def handle_call(:compute_next, _from, state) do
    alive_count = Enum.count(state.neighbors, &is_alive?/1)

    next = case {state.alive, alive_count} do
      {true, 2} -> true
      {true, 3} -> true
      {false, 3} -> true
      _ -> false
    end

    {:reply, :ok, %{state | next_state: next}}
  end

  @impl true
  def handle_cast({:set_neighbors, neighbors}, state) do
    {:noreply, %{state | neighbors: neighbors}}
  end

  @impl true
  def handle_cast(:apply_next, state) do
    {:noreply, %{state | alive: state.next_state}}
  end

  @impl true
  def handle_cast({:set_state, alive?}, state) do
    {:noreply, %{state | alive: alive?, next_state: alive?}}
  end
end

defmodule ConwaysGame.Grid do
  @moduledoc "Grid coordinator for distributed cells"

  def create(width, height, nodes \\ [node()]) do
    grid = for x <- 0..(width - 1), y <- 0..(height - 1), into: %{} do
      {{x, y}, spawn_cell(select_node(x, y, nodes), x, y, false)}
    end
    setup_neighbors(grid, width, height)
    grid
  end

  def random(width, height, density, nodes \\ [node()]) do
    grid = for x <- 0..(width - 1), y <- 0..(height - 1), into: %{} do
      {{x, y}, spawn_cell(select_node(x, y, nodes), x, y, :rand.uniform() < density)}
    end
    setup_neighbors(grid, width, height)
    grid
  end

  def glider(width, height, x \\ 1, y \\ 1, nodes \\ [node()]) do
    grid = create(width, height, nodes)

    [{x+1, y}, {x+2, y+1}, {x, y+2}, {x+1, y+2}, {x+2, y+2}]
    |> Enum.each(fn {px, py} ->
      if px < width and py < height do
        grid |> Map.get({px, py}) |> ConwaysGame.Cell.set_state(true)
      end
    end)

    grid
  end

  def next_generation(grid) do
    Enum.each(grid, fn {_, pid} -> ConwaysGame.Cell.compute_next(pid) end)
    Enum.each(grid, fn {_, pid} -> ConwaysGame.Cell.apply_next(pid) end)
  end

  def get_state(grid) do
    Enum.into(grid, %{}, fn {pos, pid} -> {pos, ConwaysGame.Cell.is_alive?(pid)} end)
  end

  defp spawn_cell(node, x, y, alive?) do
    parent = self()
    ref = make_ref()

    Node.spawn(node, fn ->
      {:ok, pid} = ConwaysGame.Cell.start_link(x, y, alive?)
      send(parent, {ref, pid})
      Process.sleep(:infinity)
    end)

    receive do
      {^ref, pid} -> pid
    after
      5000 -> raise "Cell timeout"
    end
  end

  defp setup_neighbors(grid, width, height) do
    Enum.each(grid, fn {{x, y}, pid} ->
      neighbors = for dx <- -1..1, dy <- -1..1,
                      {dx, dy} != {0, 0},
                      nx = x + dx, ny = y + dy,
                      nx >= 0 and nx < width and ny >= 0 and ny < height,
                      do: Map.get(grid, {nx, ny})

      ConwaysGame.Cell.set_neighbors(pid, Enum.reject(neighbors, &is_nil/1))
    end)
  end

  defp select_node(x, y, nodes), do: Enum.at(nodes, rem(x + y, length(nodes)))
end

defmodule ConwaysGame.Display do
  @moduledoc "Terminal display"

  def render(state, width, height) do
    IO.puts("\n" <> String.duplicate("=", width * 2))

    for y <- 0..(height - 1) do
      0..(width - 1)
      |> Enum.map(fn x -> if Map.get(state, {x, y}), do: "██", else: "··" end)
      |> Enum.join()
      |> IO.puts()
    end

    IO.puts(String.duplicate("=", width * 2))
  end
end

defmodule ConwaysGame.DisplayServer do
  @moduledoc "Local display server on each node"
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def ensure_started(node) do
    case :rpc.call(node, __MODULE__, :start_link, [[]]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :error
    end
  end

  def update(node, state, width, height, gen, running) do
    GenServer.cast({__MODULE__, node}, {:display, state, width, height, gen, running})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(:ok) do
    IO.puts("🖥️  DisplayServer active on #{node()}")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:display, state, width, height, gen, running}, s) do
    IO.write("\e[2J\e[H")
    ConwaysGame.Display.render(state, width, height)
    status = if running, do: "▶️ Running", else: "⏸️ Paused"
    IO.puts("#{status} | Gen: #{gen} | Node: #{node()}")
    {:noreply, s}
  end
end

defmodule ConwaysGame.Interactive do
  @moduledoc "Interactive game controller"
  use GenServer

  def start_link(w \\ 30, h \\ 30) do
    GenServer.start_link(__MODULE__, {w, h}, name: {:global, __MODULE__})
  end

  def start_game, do: cast(:start)
  def pause_game, do: cast(:pause)
  def toggle_cell(x, y), do: cast({:toggle, x, y})
  def reset, do: cast(:reset)
  def load_random(d \\ 0.3), do: cast({:random, d})
  def load_glider, do: cast(:glider)
  def show, do: cast(:show)
  def status, do: call(:status)

  defp cast(msg), do: GenServer.cast({:global, __MODULE__}, msg)
  defp call(msg), do: GenServer.call({:global, __MODULE__}, msg)

  @impl true
  def init({width, height}) do
    connect_cluster()
    Process.sleep(200)

    ConwaysGame.DisplayServer.start_link()
    nodes = [node() | Node.list()]
    Enum.each(nodes -- [node()], &ConwaysGame.DisplayServer.ensure_started/1)
    Process.sleep(300)

    grid = ConwaysGame.Grid.create(width, height, nodes)
    state = %{grid: grid, width: width, height: height, running: false, gen: 0, timer: nil}

    IO.puts("\n🎮 Conway's Game of Life | #{width}x#{height} | Nodes: #{inspect(nodes)}")
    print_help()
    broadcast(state)

    {:ok, state}
  end

  @impl true
  def handle_cast(:start, %{running: true} = s), do: {:noreply, s}
  def handle_cast(:start, s) do
    {:ok, timer} = :timer.send_interval(500, self(), :tick)
    {:noreply, %{s | running: true, timer: timer}}
  end

  @impl true
  def handle_cast(:pause, %{running: true, timer: t} = s) do
    :timer.cancel(t)
    {:noreply, %{s | running: false, timer: nil}}
  end
  def handle_cast(:pause, s), do: {:noreply, s}

  @impl true
  def handle_cast({:toggle, x, y}, s) when x >= 0 and x < s.width and y >= 0 and y < s.height do
    pid = Map.get(s.grid, {x, y})
    ConwaysGame.Cell.set_state(pid, not ConwaysGame.Cell.is_alive?(pid))
    broadcast(s)
    {:noreply, s}
  end
  def handle_cast({:toggle, _, _}, s), do: {:noreply, s}

  @impl true
  def handle_cast(:reset, s) do
    if s.timer, do: :timer.cancel(s.timer)
    grid = ConwaysGame.Grid.create(s.width, s.height, [node() | Node.list()])
    new = %{s | grid: grid, gen: 0, running: false, timer: nil}
    broadcast(new)
    {:noreply, new}
  end

  @impl true
  def handle_cast({:random, d}, s) do
    if s.timer, do: :timer.cancel(s.timer)
    grid = ConwaysGame.Grid.random(s.width, s.height, d, [node() | Node.list()])
    new = %{s | grid: grid, gen: 0, running: false, timer: nil}
    broadcast(new)
    {:noreply, new}
  end

  @impl true
  def handle_cast(:glider, s) do
    if s.timer, do: :timer.cancel(s.timer)
    grid = ConwaysGame.Grid.glider(s.width, s.height, 5, 5, [node() | Node.list()])
    new = %{s | grid: grid, gen: 0, running: false, timer: nil}
    broadcast(new)
    {:noreply, new}
  end

  @impl true
  def handle_cast(:show, s) do
    broadcast(s)
    {:noreply, s}
  end

  @impl true
  def handle_call(:status, _from, s) do
    {:reply, %{gen: s.gen, running: s.running, nodes: [node() | Node.list()]}, s}
  end

  @impl true
  def handle_info(:tick, s) do
    ConwaysGame.Grid.next_generation(s.grid)
    new = %{s | gen: s.gen + 1}
    broadcast(new)
    {:noreply, new}
  end

  defp broadcast(s) do
    state = ConwaysGame.Grid.get_state(s.grid)
    Enum.each([node() | Node.list()], fn n ->
      ConwaysGame.DisplayServer.update(n, state, s.width, s.height, s.gen, s.running)
    end)
  end

  defp connect_cluster do
    nodes = Application.get_env(:conways_game, :cluster_nodes, []) -- [node()]
    if nodes != [] do
      IO.puts("🔗 Connecting to cluster...")
      Enum.each(nodes, &Node.connect/1)
    end
  end

end
