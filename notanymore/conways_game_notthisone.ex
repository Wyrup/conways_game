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

  def handle_cast({:set_alive, value}, state) do
  {:noreply, %{state | alive: value, next_state: value}}
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
        target_node = select_node(x, y, nodes)

        # Créer le processus avec spawn qui envoie le PID au parent
        pid = create_cell_on_node(target_node, x, y, false)

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
        target_node = select_node(x, y, nodes)

        pid = create_cell_on_node(target_node, x, y, alive?)

        {{x, y}, pid}
      end

    setup_neighbors(grid_map, width, height)
    grid_map
  end

  def glider(width, height, start_x \\ 1, start_y \\ 1, nodes \\ [node()]) do
    # Créer une grille vide
    grid_map =
      for x <- 0..(width - 1),
          y <- 0..(height - 1),
          into: %{} do
        target_node = select_node(x, y, nodes)
        pid = create_cell_on_node(target_node, x, y, false)
        {{x, y}, pid}
      end

    # Pattern du glider:
    #   □■□
    #   □□■
    #   ■■■
    glider_positions = [
      {start_x + 1, start_y},
      {start_x + 2, start_y + 1},
      {start_x, start_y + 2},
      {start_x + 1, start_y + 2},
      {start_x + 2, start_y + 2}
    ]

    # Activer les cellules du glider
    Enum.each(glider_positions, fn {x, y} ->
      if x >= 0 and x < width and y >= 0 and y < height do
        pid = Map.get(grid_map, {x, y})
        if pid, do: ConwaysGame.Cell.set_alive(pid)
      end
    end)

    setup_neighbors(grid_map, width, height)
    grid_map
  end

  # Nouvelle fonction pour créer une cellule sur un nœud spécifique
  defp create_cell_on_node(target_node, x, y, alive?) do
    parent = self()
    ref = make_ref()

    # Spawner un processus sur le nœud cible
    Node.spawn(target_node, fn ->
      {:ok, pid} = ConwaysGame.Cell.start_link(x, y, alive?)
      send(parent, {ref, pid})
      # Garder ce processus en vie pour maintenir la cellule
      Process.sleep(:infinity)
    end)

    # Attendre le PID
    receive do
      {^ref, pid} -> pid
    after
      5000 -> raise "Timeout creating cell at (#{x}, #{y}) on #{target_node}"
    end
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
    index = rem(x + y, length(nodes))
    Enum.at(nodes, index)
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
      if Map.get(grid_state, {x, y}, false), do: "██", else: "··"
    end
    IO.puts(Enum.join(row, ""))
  end

  IO.puts(String.duplicate("=", width * 2))
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

defmodule ConwaysGame.Interactive do
  @moduledoc """
  Interface interactive en terminal pour le jeu de la vie.
  Distribue l'affichage sur tous les nœuds connectés.
  Contrôlable depuis n'importe quel nœud.
  """
  use GenServer

  # API Client - Modifiées pour fonctionner depuis n'importe quel nœud

  def start_link(width \\ 30, height \\ 30) do
    # Enregistrement global pour accès depuis tous les nœuds
    GenServer.start_link(__MODULE__, {width, height}, name: {:global, __MODULE__})
  end

  def start_game do
    GenServer.cast({:global, __MODULE__}, :start)
  end

  def pause_game do
    GenServer.cast({:global, __MODULE__}, :pause)
  end

  def toggle_cell(x, y) do
    GenServer.cast({:global, __MODULE__}, {:toggle_cell, x, y})
  end

  def reset do
    GenServer.cast({:global, __MODULE__}, :reset)
  end

  def load_random(density \\ 0.3) do
    GenServer.cast({:global, __MODULE__}, {:load_random, density})
  end

  def load_glider do
    GenServer.cast({:global, __MODULE__}, :load_glider)
  end

  def show do
    GenServer.cast({:global, __MODULE__}, :show)
  end

  def status do
    GenServer.call({:global, __MODULE__}, :status)
  end

  # Diffuser l'affichage sur tous les DisplayServers
  defp broadcast_display(grid_state, width, height, generation, running) do
    nodes = ConwaysGame.Cluster.list_nodes()

    Enum.each(nodes, fn node ->
      ConwaysGame.DisplayServer.update_display(node, grid_state, width, height, generation, running)
    end)
  end

  # Callbacks GenServer

  def init({width, height}) do
    # 1. Connexion au cluster
    auto_connect_cluster()

    # 2. Attendre un peu que la connexion soit établie
    Process.sleep(200)

    # 3. Démarrer DisplayServer LOCAL
    case ConwaysGame.DisplayServer.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # 4. Récupérer les nœuds (maintenant connectés)
    nodes = ConwaysGame.Cluster.list_nodes()

    # 5. Démarrer DisplayServer sur les nœuds DISTANTS
    IO.puts("📡 Initialisation des DisplayServers...")
    Enum.each(nodes -- [node()], fn remote_node ->
      ConwaysGame.DisplayServer.ensure_started_on_node(remote_node)
    end)

    # 6. Pause pour s'assurer que tout est prêt
    Process.sleep(500)

    IO.puts("Using nodes: #{inspect(nodes)}")
    grid = ConwaysGame.Grid.create(width, height, nodes)

    state = %{
      grid: grid,
      width: width,
      height: height,
      running: false,
      generation: 0,
      timer_ref: nil
    }

    IO.puts("\n🎮 Conway's Game of Life - Mode Interactif")
    IO.puts("Grille: #{width}x#{height}")
    IO.puts("⚡ Contrôlable depuis n'importe quel nœud du cluster")
    print_help()

    # Afficher sur tous les nœuds
    grid_state = ConwaysGame.Grid.get_state(state.grid)
    broadcast_display(grid_state, state.width, state.height, state.generation, state.running)

    {:ok, state}
  end

  def handle_cast(:start, state) do
    if state.running do
      {:noreply, state}
    else
      # Broadcast sur tous les nœuds
      Enum.each(ConwaysGame.Cluster.list_nodes(), fn node ->
        :rpc.cast(node, IO, :puts, ["▶️  Démarrage de la simulation..."])
      end)

      {:ok, timer_ref} = :timer.send_interval(500, self(), :tick)
      {:noreply, %{state | running: true, timer_ref: timer_ref}}
    end
  end

  def handle_cast(:pause, state) do
    if state.running and state.timer_ref do
      :timer.cancel(state.timer_ref)

      # Broadcast sur tous les nœuds
      Enum.each(ConwaysGame.Cluster.list_nodes(), fn node ->
        :rpc.cast(node, IO, :puts, ["⏸️  Simulation en pause"])
      end)

      {:noreply, %{state | running: false, timer_ref: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:toggle_cell, x, y}, state) do
    if x >= 0 and x < state.width and y >= 0 and y < state.height do
      pid = Map.get(state.grid, {x, y})
      current = ConwaysGame.Cell.is_alive?(pid)

      if current do
        GenServer.cast(pid, {:set_alive, false})
        Enum.each(ConwaysGame.Cluster.list_nodes(), fn node ->
          :rpc.cast(node, IO, :puts, ["❌ Cellule (#{x}, #{y}) désactivée"])
        end)
      else
        GenServer.cast(pid, :set_alive)
        Enum.each(ConwaysGame.Cluster.list_nodes(), fn node ->
          :rpc.cast(node, IO, :puts, ["✅ Cellule (#{x}, #{y}) activée"])
        end)
      end

      grid_state = ConwaysGame.Grid.get_state(state.grid)
      broadcast_display(grid_state, state.width, state.height, state.generation, state.running)
    else
      Enum.each(ConwaysGame.Cluster.list_nodes(), fn node ->
        :rpc.cast(node, IO, :puts, ["⚠️  Position invalide: (#{x}, #{y})"])
      end)
    end

    {:noreply, state}
  end

  def handle_cast(:reset, state) do
    if state.timer_ref, do: :timer.cancel(state.timer_ref)

    grid = ConwaysGame.Grid.create(state.width, state.height)
    new_state = %{state | grid: grid, generation: 0, running: false, timer_ref: nil}

    Enum.each(ConwaysGame.Cluster.list_nodes(), fn node ->
      :rpc.cast(node, IO, :puts, ["🔄 Grille réinitialisée"])
    end)

    grid_state = ConwaysGame.Grid.get_state(new_state.grid)
    broadcast_display(grid_state, new_state.width, new_state.height, new_state.generation, new_state.running)

    {:noreply, new_state}
  end

  def handle_cast({:load_random, density}, state) do
    if state.timer_ref, do: :timer.cancel(state.timer_ref)

    grid = ConwaysGame.Grid.random(state.width, state.height, density, ConwaysGame.Cluster.list_nodes())
    new_state = %{state | grid: grid, generation: 0, running: false, timer_ref: nil}

    Enum.each(ConwaysGame.Cluster.list_nodes(), fn node ->
      :rpc.cast(node, IO, :puts, ["🎲 Grille aléatoire chargée (densité: #{density})"])
    end)

    grid_state = ConwaysGame.Grid.get_state(new_state.grid)
    broadcast_display(grid_state, new_state.width, new_state.height, new_state.generation, new_state.running)

    {:noreply, new_state}
  end

  def handle_cast(:load_glider, state) do
    if state.timer_ref, do: :timer.cancel(state.timer_ref)

    grid = ConwaysGame.Grid.glider(state.width, state.height, 5, 5, ConwaysGame.Cluster.list_nodes())
    new_state = %{state | grid: grid, generation: 0, running: false, timer_ref: nil}

    Enum.each(ConwaysGame.Cluster.list_nodes(), fn node ->
      :rpc.cast(node, IO, :puts, ["🛸 Glider chargé"])
    end)

    grid_state = ConwaysGame.Grid.get_state(new_state.grid)
    broadcast_display(grid_state, new_state.width, new_state.height, new_state.generation, new_state.running)

    {:noreply, new_state}
  end

  def handle_cast(:show, state) do
    grid_state = ConwaysGame.Grid.get_state(state.grid)
    broadcast_display(grid_state, state.width, state.height, state.generation, state.running)
    {:noreply, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      generation: state.generation,
      running: state.running,
      width: state.width,
      height: state.height,
      controller_node: node()
    }
    {:reply, status, state}
  end

  def handle_info(:tick, state) do
    ConwaysGame.Grid.next_generation(state.grid)
    new_state = %{state | generation: state.generation + 1}

    grid_state = ConwaysGame.Grid.get_state(new_state.grid)
    broadcast_display(grid_state, new_state.width, new_state.height, new_state.generation, new_state.running)

    {:noreply, new_state}
  end

  # Helpers privés

  defp print_help do
    IO.puts("""

    📖 Commandes disponibles (depuis n'importe quel terminal):

    ConwaysGame.Interactive.start_game()      # ▶️  Démarrer
    ConwaysGame.Interactive.pause_game()      # ⏸️  Pause
    ConwaysGame.Interactive.toggle_cell(x,y)  # 🔄 Toggle cellule
    ConwaysGame.Interactive.reset()           # 🔄 Reset
    ConwaysGame.Interactive.load_random(0.3)  # 🎲 Grille aléatoire
    ConwaysGame.Interactive.load_glider()     # 🛸 Charger glider
    ConwaysGame.Interactive.show()            # 👁️  Afficher grille
    ConwaysGame.Interactive.status()          # 📊 Afficher status

    Alias pratiques:
    alias ConwaysGame.Interactive, as: Game
    Game.start_game()
    """)
  end

  defp auto_connect_cluster do
    target_nodes = Application.get_env(:conways_game, :cluster_nodes, [])
    nodes_to_connect = target_nodes -- [node()]

    if nodes_to_connect != [] do
      IO.puts("🔗 Connexion automatique au cluster...")
      ConwaysGame.Cluster.connect_nodes(nodes_to_connect)
    end
  end
end

# Ajoutez ce module à la fin de lib/conways_game.ex

defmodule ConwaysGame.DisplayServer do
  @moduledoc """
  Serveur d'affichage local sur chaque nœud.
  Reçoit les mises à jour et affiche dans son terminal.
  """
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def ensure_started_on_node(node) do
    result = :rpc.call(node, ConwaysGame.DisplayServer, :start_link, [[]])

    case result do
      {:ok, pid} ->
        IO.puts("✅ DisplayServer démarré sur #{node} (PID: #{inspect(pid)})")
        :ok
      {:error, {:already_started, pid}} ->
        IO.puts("ℹ️  DisplayServer actif sur #{node} (PID: #{inspect(pid)})")
        :ok
      {:badrpc, reason} ->
        IO.puts("❌ RPC failed sur #{node}: #{inspect(reason)}")
        :error
      error ->
        IO.puts("❌ Erreur sur #{node}: #{inspect(error)}")
        :error
    end
  end

  def update_display(node, grid_state, width, height, generation, running) do
    # Utiliser directement GenServer.cast sans vérifier - le cast échouera silencieusement si le serveur n'existe pas
    try do
      GenServer.cast({__MODULE__, node}, {:display, grid_state, width, height, generation, running})
    catch
      :exit, _ ->
        IO.puts("⚠️  Impossible d'envoyer à DisplayServer sur #{node}")
    end
  end

  def init(:ok) do
    IO.puts("🖥️  DisplayServer démarré sur #{node()}")
    {:ok, %{}}
  end

  def handle_cast({:display, grid_state, width, height, generation, running}, state) do
    # Clear screen
    IO.write("\e[2J\e[H")

    ConwaysGame.Display.terminal(grid_state, width, height)

    status_text = if running, do: "▶️  Running", else: "⏸️  Paused"
    IO.puts("Status: #{status_text} | Génération: #{generation} | Nœud: #{node()}")

    {:noreply, state}
  end
end
