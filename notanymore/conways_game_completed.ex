defmodule ConwaysGame do
  @moduledoc """
  Implémentation distribuée du jeu de la vie de Conway.
  Chaque cellule est un processus Elixir distinct.
  """

  @doc """
  Point d'entrée principal pour lancer le jeu.
  """
  def start(width \\ 30, height \\ 30) do

    nodes = [node() | Node.list()]
    IO.puts("Distribution sur #{length(nodes)} nœud(s): #{inspect(nodes)}")
    IO.puts("Création de la grille #{width}x#{height}...")
    grid = ConwaysGame.Grid.create(width, height, nodes)

    IO.puts("Initialisation aléatoire...")
    ConwaysGame.Grid.fill_random(grid, 0.3)

    {:ok, game_pid} = ConwaysGame.GameLoop.start_link(grid, width, height)

    IO.puts("\nCommandes disponibles:")
    IO.puts("  s - start/pause")
    IO.puts("  n - next step (mode pause)")
    IO.puts("  r - shuffle random")
    IO.puts("  c - ajouter/retirer une cellule (coords x,y)")
    IO.puts("  q - quitter")
    IO.puts("")

    interactive_loop(game_pid, grid)
  end

  defp interactive_loop(game_pid, grid) do
    raw_input = IO.gets("> ")
    input = String.trim(raw_input)

    case input do
      "s" ->
        ConwaysGame.GameLoop.toggle_pause(game_pid)
        interactive_loop(game_pid, grid)

      "n" ->
        ConwaysGame.GameLoop.step(game_pid)
        interactive_loop(game_pid, grid)

      "r" ->
        ConwaysGame.GameLoop.shuffle(game_pid)
        interactive_loop(game_pid, grid)

      "c" ->
        IO.puts("Entrez les coordonnées (x,y):")
        raw_coords = IO.gets("coords> ")
        coords = String.trim(raw_coords)
        case parse_coords(coords) do
          {:ok, x, y} ->
            ConwaysGame.GameLoop.toggle_cell(game_pid, {x, y})
            IO.puts("Cellule (#{x},#{y}) modifiée")
          :error ->
            IO.puts("Format invalide. Utilisez: x,y")
        end
        interactive_loop(game_pid, grid)

      "q" ->
        ConwaysGame.GameLoop.stop(game_pid)
        IO.puts("Au revoir!")
        :ok

      _ ->
        IO.puts("Commande inconnue")
        interactive_loop(game_pid, grid)
    end
  end

  defp parse_coords(coords) do
    case String.split(coords, ",") do
      [x_str, y_str] ->
        trimmed_x = String.trim(x_str)
        trimmed_y = String.trim(y_str)
        with {x, _} <- Integer.parse(trimmed_x),
             {y, _} <- Integer.parse(trimmed_y) do
          {:ok, x, y}
        else
          _ -> :error
        end
      _ -> :error
    end
  end
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
    # FIX: is_alive? retourne un booléen, pas un tuple
    alive_statuses = Enum.map(state.neighbors, fn neighbor_pid -> is_alive?(neighbor_pid) end)
    alive_count = Enum.count(alive_statuses, fn alive? -> alive? == true end)

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
    case Map.get(grid_map, {x, y}) do
      nil ->
        :error

      pid ->
        current_state = ConwaysGame.Cell.is_alive?(pid)
        ConwaysGame.Cell.set_alive(pid, not current_state)
        :ok
    end
  end

  def step(grid_map) do
    # Phase 1: Toutes les cellules calculent leur prochain état
    Enum.each(grid_map, fn {_pos, pid} ->
      ConwaysGame.Cell.compute_next_state(pid)
    end)

    # Phase 2: Toutes les cellules appliquent leur nouveau état
    Enum.each(grid_map, fn {_pos, pid} ->
      ConwaysGame.Cell.apply_next_state(pid)
    end)
  end

  defp select_node(x, y, nodes), do: Enum.at(nodes, rem(x + y, length(nodes)))

  defp spawn_cell(node, x, y, alive?) do
    parent = self()

    Node.spawn_link(node, fn ->
      {:ok, pid} = ConwaysGame.Cell.start_link(x, y, alive?)
      send(parent, {{x, y}, pid})
    end)

    receive do
      {{x_, y_}, pid_} ->
        {{x_, y_}, pid_}
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
            nx >= 0 and nx < width and ny >= 0 and ny < height do
          # FIX: utiliser nx, ny au lieu de x, y
          Map.get(grid, {nx, ny})
        end

      filtered_neighbors = Enum.reject(neighbors, &is_nil/1)
      ConwaysGame.Cell.set_neighbors(pid, filtered_neighbors)
    end)
  end
end

defmodule ConwaysGame.GameLoop do
  @moduledoc """
  Boucle de jeu principale avec gestion start/pause et affichage.
  """
  use GenServer

  @refresh_rate 200  # ms entre chaque frame

  defmodule State do
    defstruct [
      :grid_map,
      :width,
      :height,
      :running,
      :generation,
      :timer_ref
    ]
  end

  # API Client

  def start_link(grid_map, width, height) do
    GenServer.start_link(__MODULE__, {grid_map, width, height})
  end

  def toggle_pause(pid) do
    GenServer.call(pid, :toggle_pause)
  end

  def step(pid) do
    GenServer.call(pid, :step)
  end

  def shuffle(pid) do
    GenServer.call(pid, :shuffle)
  end

  def toggle_cell(pid, coords) do
    GenServer.call(pid, {:toggle_cell, coords})
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  # Callbacks GenServer

  @impl true
  def init({grid_map, width, height}) do
    state = %State{
      grid_map: grid_map,
      width: width,
      height: height,
      running: false,
      generation: 0,
      timer_ref: nil
    }

    render(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:toggle_pause, _from, state) do
    new_state =
      if state.running do
        # Pause
        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
        IO.puts("\n[PAUSE]")
        %{state | running: false, timer_ref: nil}
      else
        # Start
        IO.puts("\n[RUNNING]")
        timer_ref = schedule_tick()
        %{state | running: true, timer_ref: timer_ref}
      end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:step, _from, state) do
    new_state = do_step(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:shuffle, _from, state) do
    ConwaysGame.Grid.fill_random(state.grid_map, 0.3)
    new_state = %{state | generation: 0}
    render(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:toggle_cell, coords}, _from, state) do
    ConwaysGame.Grid.change_cell(state.grid_map, coords)
    render(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = do_step(state)
    timer_ref = if new_state.running, do: schedule_tick(), else: nil
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  # Helpers privés

  defp do_step(state) do
    ConwaysGame.Grid.step(state.grid_map)
    new_state = %{state | generation: state.generation + 1}
    render(new_state)
    new_state
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @refresh_rate)
  end

  defp render(state) do
    # Efface l'écran
    clear_screen = IO.ANSI.clear() <> IO.ANSI.home()
    IO.write(clear_screen)

    # Header
    status = if state.running, do: "RUNNING", else: "PAUSED"
    IO.puts("╔═══════════════════════════════════════════════════════╗")
    IO.puts("║  Conway's Game of Life - Generation: #{state.generation} [#{status}]")
    IO.puts("╚═══════════════════════════════════════════════════════╝")
    IO.puts("")

    # Grille
    for y <- 0..(state.height - 1) do
      line =
        for x <- 0..(state.width - 1) do
          pid = Map.get(state.grid_map, {x, y})
          if ConwaysGame.Cell.is_alive?(pid) do
            IO.ANSI.green() <> "██" <> IO.ANSI.reset()
          else
            IO.ANSI.black() <> "··" <> IO.ANSI.reset()
          end
        end

      joined_line = Enum.join(line, "")
      IO.puts(joined_line)
    end

    IO.puts("")
  end
end
