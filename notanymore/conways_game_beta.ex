defmodule ConwaysGame do
  @moduledoc """
  Implémentation distribuée du jeu de la vie de Conway.
  Chaque cellule est un processus Elixir distinct.
  """
end

defmodule ConwaysGame.Cell do
  @moduledoc """
  Processus représentant une cellule individuelle.
  """

  use GenServer

  @doc """
  Démarre un processus cellule à la position {x, y}.
  État initial: {alive?, neighbors_pids, position}
  """
  def start_link(x, y, alive? \\ false) do
    GenServer.start_link(__MODULE__, {x, y, alive?})
  end

  @doc """
  Enregistre les PIDs des 8 voisins de cette cellule.
  """
  def set_neighbors(cell_pid, neighbors_pids) do
    GenServer.call(cell_pid, {:set_neighbors, neighbors_pids})
  end

  @doc """
  Demande à la cellule de calculer son prochain état.
  La cellule interroge ses voisins pour compter les vivants.
  """
  def compute_next_state(cell_pid) do
    GenServer.call(cell_pid, :compute_next)
  end

  @doc """
  Applique le nouvel état (après que toutes les cellules aient calculé).
  """
  def apply_next_state(cell_pid) do
    GenServer.call(cell_pid, :apply_next)
  end

  @doc """
  Retourne si la cellule est vivante (pour que les voisins puissent interroger).
  """
  def is_alive?(cell_pid) do
    GenServer.call(cell_pid, :is_alive)
  end

  @doc """
  Change l'état de la cellule, par défaut true
  """
  def set_alive(cell_pid, alive? \\ true) do
    GenServer.call(cell_pid, {:set_alive, alive?})
  end

  @impl true
  def init({x, y, alive?}) do
    state = %{
      position: {x, y},
      alive: alive?,
      neighbors: [],
      next_state: alive?
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_neighbors, neighbors_pids}, _from, state) do
    {:reply, :ok, %{state | neighbors: neighbors_pids}}
  end

  @impl true
  def handle_call(:compute_next, _from, state) do
    alive_count =
      Enum.count(
        Enum.map(state.neighbors, fn neighbors_pid ->
          is_alive?(neighbors_pid)
        end),
        fn {_, alive?, _} ->
          alive? == true
        end
      )

    next_state =
      case {state.alive, alive_count} do
        {true, 2} -> true
        {true, 3} -> true
        {false, 3} -> true
        _ -> false
      end

    new_state = %{state | next_state: next_state}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:apply_next, _from, state) do
    {:reply, :ok, %{state | alive: state.next_state}}
  end

  @impl true
  def handle_call(:is_alive, _from, state) do
    {:reply, state.alive, state}
  end

  @impl true
  def handle_call({:set_alive, alive?}, _from, state) do
    {:reply, :ok, %{state | alive: alive?, next_state: alive?}}
  end
end

defmodule ConwaysGame.Grid do
  @moduledoc """
  Gestionnaire de la grille - supervise et coordonne toutes les cellules.
  """
  use GenServer

  @doc """
  Crée une grille de cellules (processus) sur plusieurs nœuds.
  Retourne une map: %{{x, y} => cell_pid}
  """
  def create(width, height, nodes \\ [node()]) do
    # Phase 1: Créer les cellules
    grid_map =
      for x <- 0..(width - 1),
          y <- 0..(height - 1),
          into: %{} do
        # Créer le processus avec spawn qui envoie le PID au parent
        # {{x, y}, spawn_cell(select_node(x, y, nodes), x, y, false)}
        spawn_cell(select_node(x, y, nodes), x, y, false)
      end

    # Phase 2: Configurer les voisins
    setup_neighbors(grid_map, width, height)

    grid_map
  end

  def fill_random(grid_map, density \\ 0.3) do
    Enum.each(grid_map, fn {_pos, pid} ->
      alive? = :rand.uniform() < density
      ConwaysGame.Cell.set_alive(pid, alive?)
    end)
  end

  def change_cell(grid_map, {x, y}) do
    case pid = Map.get(grid_map, {x, y}) do
      nil ->
        :error

      pid ->
        current_state = ConwaysGame.Cell.is_alive?(pid)
        ConwaysGame.Cell.set_alive(pid, not current_state)
        :ok
    end
  end

  defp select_node(x, y, nodes), do: Enum.at(nodes, rem(x + y, length(nodes)))

  defp spawn_cell(node, x, y, alive?) do
    Node.spawn_link(node, fn ->
      {:ok, pid} = ConwaysGame.Cell.start_link(x, y, alive?)
      send(self(), {{x, y}, pid})
    end)

    receive do
      {{x_, y_}, pid_} ->
        {{x_, y_}, pid_}
        # after
        #   #### Optional timeout
        #   30_000 -> :timeout
    end
  end

  defp setup_neighbors(grid, width, height) do
    Enum.each(grid, fn {{x, y}, pid} ->
      neighbors =
        for dx <- -1..1,
            dy <- -1..1,
            {dx, dy} != {0, 0},
            nx = x + dx,
            ny = y + dy,
            nx >= 0 and nx < width and ny >= 0 and ny < height,
            do: Map.get(grid, {nx, ny})

      # Enum.reject is_nil potentiel
      ConwaysGame.Cell.set_neighbors(pid, neighbors)
    end)
  end
end
