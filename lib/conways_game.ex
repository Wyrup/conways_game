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
    GenServer.cast(cell_pid, {:set_neighbors, neighbors_pids})
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
    GenServer.cast(cell_pid, :apply_next)
  end

  @doc """
  Retourne si la cellule est vivante (pour que les voisins puissent interroger).
  """
  def is_alive?(cell_pid) do
    GenServer.call(cell_pid, :is_alive)
  end

  # Callbacks GenServer
  def init({x, y, alive?}) do
    state = %{
      position: {x, y},
      alive: alive?,
      neighbors: [],
      next_state: alive?
    }
    {:ok, state}
  end

  def handle_call(:is_alive, _from, state) do
    {:reply, state.alive, state}
  end

  def handle_call(:compute_next, _from, state) do
    # demande aux voisins s'ils sont vivants
    alive_count =
      state.neighbors
      |> Enum.map(fn neighbor_pid ->
        # Communication par message avec chaque voisin
        is_alive?(neighbor_pid)
      end)
      |> Enum.count(& &1)
    # Applique les règles du jeu de la vie
    next_state = case {state.alive, alive_count} do
      {true, 2} -> true
      {true, 3} -> true
      {false, 3} -> true
      _ -> false
    end

    new_state = %{state | next_state: next_state}
    {:reply, :ok, new_state}
  end

  def handle_cast({:set_neighbors, neighbors}, state) do
    {:noreply, %{state | neighbors: neighbors}}
  end

  def handle_cast(:apply_next, state) do
    {:noreply, %{state | alive: state.next_state}}
  end
end

defmodule ConwaysGame.Grid do
  @moduledoc """
  Gestionnaire de la grille - supervise et coordonne toutes les cellules.
  """

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
        node = select_node(x, y, nodes)
        {:ok, pid} = :rpc.call(node, ConwaysGame.Cell, :start_link, [x, y, false])
        {{x, y}, pid}
      end
    # Phase 2: Configurer les voisins
    setup_neighbors(grid_map, width, height)

    grid_map
  end

  @doc """
  Initialise une grille avec un pattern aléatoire.
  """
  def random(width, height, density, nodes) do
    grid_map =
      for x <- 0..(width - 1),
          y <- 0..(height - 1),
          into: %{} do
        alive? = :rand.uniform() < density
        node = select_node(x, y, nodes)
        {:ok, pid} = :rpc.call(node, ConwaysGame.Cell, :start_link, [x, y, alive?])
        {{x, y}, pid}
      end
    setup_neighbors(grid_map, width, height)
    grid_map
  end

  @doc """
  Configure les voisins pour chaque cellule de la grille.
  """
  def setup_neighbors(grid_map, width, height) do
    Enum.each(grid_map, fn {{x, y}, cell_pid} ->
      neighbor_pids =
        get_neighbor_positions(x, y, width, height)
        |> Enum.map(fn pos -> Map.get(grid_map, pos) end)
        |> Enum.reject(&is_nil/1)

      # Message envoyé à la cellule avec ses voisins
      ConwaysGame.Cell.set_neighbors(cell_pid, neighbor_pids)
    end)
  end

  @doc """
  Exécute une génération: toutes les cellules calculent puis appliquent leur nouvel état.
  """
  def next_generation(grid_map) do
    # Phase 1: Calculer le prochain état
    Enum.each(grid_map, fn {_pos, cell_pid} ->
      ConwaysGame.Cell.compute_next_state(cell_pid)
    end)
    # Phase 2: Appliquer le nouvel état
    Enum.each(grid_map, fn {_pos, cell_pid} ->
      ConwaysGame.Cell.apply_next_state(cell_pid)
    end)
  end

  @doc """
  Récupère l'état actuel de toutes les cellules pour affichage.
  Retourne: %{{x, y} => alive?}
  """
  def get_state(grid_map) do
    grid_map
    |> Enum.map(fn {pos, pid} ->
      {pos, ConwaysGame.Cell.is_alive?(pid)}
    end)
    |> Enum.into(%{})
  end

  defp get_neighbor_positions(x, y, width, height) do
    for dx <- -1..1,
        dy <- -1..1,
        {dx, dy} != {0, 0},
        nx = x + dx, ny = y + dy,
        nx >= 0, nx < width,
        ny >= 0, ny < height do
      {nx, ny}
    end
  end

  defp select_node(x, y, nodes) do
    # Répartition équilibrée basée sur la position
    index = rem(x * 1000 + y, length(nodes))
    Enum.at(nodes, index)
  end

  @doc """
  Répartit les cellules sur différents nœuds de manière équilibrée.
  """
  defp distribute_cells(positions, nodes) do
    positions
    |> Enum.with_index()
    |> Enum.map(fn {pos, idx} ->
      node = Enum.at(nodes, rem(idx, length(nodes)))
      {pos, node}
    end)
  end
end

defmodule ConwaysGame.Supervisor do
  @moduledoc """
  Superviseur pour les cellules et la grille.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      # On peut ajouter des superviseurs pour les cellules ici si nécessaire
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule ConwaysGame.Display do
  @moduledoc """
  Module pour afficher l'état de la grille.
  """

  @doc """
  Affiche la grille dans le terminal.
  """
  def terminal(grid_state, width, height) do
    IO.puts("\n" <> String.duplicate("=", width * 2))

    for y <- 0..(height - 1) do
      row = for x <- 0..(width - 1) do
        if Map.get(grid_state, {x, y}, false), do: "■", else: "□"
      end
      IO.puts(Enum.join(row))
    end
    IO.puts(String.duplicate("=", width * 2))
  end

  @doc """
  Prépare les données pour LiveView (format JSON).
  """
  def for_liveview(grid_state) do
    grid_state
    |> Enum.filter(fn {_pos, alive?} -> alive? end)
    |> Enum.map(fn {{x, y}, _} -> %{x: x, y: y} end)
  end
end

defmodule ConwaysGame.Cluster do
  @moduledoc """
  Utilitaires pour gérer le cluster de nœuds distribués.
  """

  @doc """
  Connecte les nœuds du cluster.
  """
  def connect_nodes(node_names) do
    Enum.each(node_names, fn node_name ->
      case Node.connect(node_name) do
        true -> IO.puts("Connected to #{node_name}")
        false -> IO.puts("Failed to connect to #{node_name}")
        :ignored -> IO.puts("Already connected to #{node_name}")
      end
    end)
  end

  @doc """
  Liste les nœuds disponibles.
  """
  def list_nodes do
    [node() | Node.list()]
  end
end
