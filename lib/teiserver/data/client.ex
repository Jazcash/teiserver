defmodule Teiserver.Client do
  @moduledoc false
  alias Phoenix.PubSub
  alias Teiserver.Battle
  alias Teiserver.User
  alias Teiserver.Room
  alias Teiserver.BitParse

  def create(client) do
    Map.merge(
      %{
        status: "0",
        in_game: false,
        away: false,
        rank: 1,
        moderator: false,
        bot: false,

        # Battle stuff
        ready: false,
        team_number: 0,
        ally_team_number: 0,
        spectator: true,
        handicap: 0,
        sync: 0,
        side: 0,
        battlestatus: 0,
        team_colour: 0,
        battle_id: nil
      },
      client
    )
  end

  def login(user, pid, protocol) do
    client =
      create(%{
        userid: user.id,
        name: user.name,
        pid: pid,
        protocol: protocol,
        rank: user.rank,
        moderator: user.moderator,
        bot: user.bot,
        away: false,
        in_game: false
      })
      |> calculate_status
      |> add_client

    PubSub.broadcast(Central.PubSub, "all_client_updates", {:logged_in_client, user.id, user.name})
    client
  end

  def calculate_status(client) do
    [r1, r2, r3] = BitParse.parse_bits("#{client.rank || 1}", 3)

    status =
      [
        if(client.in_game, do: 1, else: 0),
        if(client.away, do: 1, else: 0),
        r1,
        r2,
        r3,
        if(client.moderator, do: 1, else: 0),
        if(client.bot, do: 1, else: 0)
      ]
      |> Integer.undigits(2)

    %{client | status: status}
  end

  def calculate_battlestatus(client) do
    [t1, t2, t3, t4] = BitParse.parse_bits("#{client.team_number}", 4)
    [a1, a2, a3, a4] = BitParse.parse_bits("#{client.ally_team_number}", 4)
    [h1, h2, h3, h4, h5, h6, h7] = BitParse.parse_bits("#{client.handicap}", 7)
    [sync1, sync2] = BitParse.parse_bits("#{client.sync}", 2)
    [side1, side2, side3, side4] = BitParse.parse_bits("#{client.side}", 4)

    battlestatus =
      [
        0,
        if(client.ready, do: 1, else: 0),
        t1,
        t2,
        t3,
        t4,
        a1,
        a2,
        a3,
        a4,
        if(client.spectator, do: 1, else: 0),
        h1,
        h2,
        h3,
        h4,
        h5,
        h6,
        h7,
        0,
        0,
        0,
        0,
        sync1,
        sync2,
        side1,
        side2,
        side3,
        side4,
        0,
        0,
        0,
        0
      ]
      |> Integer.undigits(2)

    %{client | battlestatus: battlestatus}
  end

  def update(client, reason \\ nil) do
    client =
      client
      |> calculate_status
      |> calculate_battlestatus
      |> add_client

    PubSub.broadcast(Central.PubSub, "all_client_updates", {:updated_client, client, reason})
    if client.battle_id, do: PubSub.broadcast(Central.PubSub, "live_battle_updates:#{client.battle_id}", {:updated_client, client, reason})
    client
  end

  def leave_battle(userid) do
    case get_client(userid) do
      nil -> nil
      client ->
        case Battle.get_battle(client.battle_id) do
          nil -> nil
            Battle.remove_user_from_battle(userid, client.battle_id)
            new_client = Map.merge(client, %{
              battlestatus: 0,
              team_colour: 0,
              battle_id: nil
            })
            ConCache.put(:clients, new_client.userid, new_client)
        end
    end
  end

  def leave_rooms(userid) do
    Room.list_rooms
    |> Enum.each(fn room ->
      if userid in room.members do
        Room.remove_user_from_room(userid, room.name)
      end
    end)
  end

  def get_client(userid) do
    ConCache.get(:clients, userid)
  end

  def get_clients(id_list) do
    id_list
    |> Enum.map(fn userid -> ConCache.get(:clients, userid) end)
  end

  def add_client(client) do
    ConCache.put(:clients, client.userid, client)

    ConCache.update(:lists, :clients, fn value ->
      new_value =
        (value ++ [client.userid])
        |> Enum.uniq()

      {:ok, new_value}
    end)

    client
  end

  def list_client_ids() do
    ConCache.get(:lists, :clients)
  end

  def list_clients() do
    ConCache.get(:lists, :clients)
    |> Enum.map(fn c -> get_client(c) end)
  end

  # It appears this isn't used but I suspect it will be at a later stage
  # def get_client_state(pid) do
  #   GenServer.call(pid, :get_state)
  # end

  def disconnect(nil), do: nil

  def disconnect(userid) do
    leave_battle(userid)
    leave_rooms(userid)

    ConCache.delete(:clients, userid)

    ConCache.update(:lists, :clients, fn value ->
      new_value =
        value
        |> Enum.filter(fn v -> v != userid end)

      {:ok, new_value}
    end)
    username = User.get_username(userid)
    PubSub.broadcast(Central.PubSub, "all_client_updates", {:logged_out_client, userid, username})
  end
end
