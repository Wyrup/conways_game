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

  def get_neighbor_positions(x, y, width, height) do
    for dx <- -1..1,
        dy <- -1..1,
        {dx, dy} != {0, 0},
        nx = x + dx,
        ny = y + dy,
        nx >= 0,
        nx < width,
        ny >= 0,
        ny < height do
      {nx, ny}
    end
  end
end
