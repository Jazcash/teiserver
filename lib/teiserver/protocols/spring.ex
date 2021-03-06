defmodule Teiserver.Protocols.SpringProtocol do
  @moduledoc """
  Protocol definition:
  https://springrts.com/dl/LobbyProtocol/ProtocolDescription.html
  """
  require Logger
  alias Regex
  alias Teiserver.Client
  alias Teiserver.Battle
  alias Teiserver.Room
  alias Teiserver.User
  alias Phoenix.PubSub
  alias Teiserver.BitParse
  alias Teiserver.TcpServer
  import Central.Helpers.NumberHelper, only: [int_parse: 1]

  # TODO - Setup/Account stuff
  # CONFIRMAGREEMENT - Waiting to hear from Beherith on how he wants it to work
  # RESENDVERIFICATION - See above

  # Need to do at some stage but not used at this time
  # DISABLEUNITS
  # ENABLEUNITS
  # ENABLEALLUNITS
  # LISTCOMPFLAGS

  @motd """
  Message of the day
  Welcome to Teiserver
  Connect on port 8201 for TLS
  ---------
  """

  # The welcome message is sent to a client when they first connect
  # to the server
  def welcome(socket, transport) do
    _send("TASSERVER 0.38-33-ga5f3b28 * 8201 0\n", socket, transport, nil)
  end

  # The main entry point for the module and the wrapper around
  # parsing, processing and acting upon a player message
  @spec handle(String.t(), Map.t()) :: Map.t()
  def handle("", state), do: state
  def handle("\r\n", state), do: state

  def handle(data, state) do
    tuple =
      ~r/^(#[0-9]+ )?([A-Z0-9]+)(.*)?$/
      |> Regex.run(data)
      |> _clean

    state =
      case tuple do
        {command, data, msg_id} ->
          do_handle(command, data, %{state | msg_id: msg_id})

        nil ->
          Logger.debug("Bad match on command: '#{data}'")
          state
      end

    %{state | msg_id: nil}
  end

  defp _clean(nil), do: nil

  defp _clean([_, msg_id, command, data]) do
    {command, String.trim(data), String.trim(msg_id)}
  end

  defp do_handle("SLTS", _, state) do
    _send("OK cmd=SLTS\n", state)
    state
  end

  defp do_handle("STLS", _, state) do
    _send("OK cmd=STLS\n", state)
    state
  end

  # Special handler to allow us to test more easily, it just accepts
  # any login. As soon as we put password checking in place this will
  # stop working
  defp do_handle("LI", username, state) do
    do_handle(
      "LOGIN",
      "#{username} X03MO1qnZdYdgyfeuILPmQ== 0 * LuaLobby Chobby\t1993717506\t0d04a635e200f308\tb sp",
      # "SPADS1[00] X03MO1qnZdYdgyfeuILPmQ== 0 192.168.1.102 SPADS v0.12.30\t0\tb_sp",
      state
    )
  end

  defp do_handle("JB", bnum, state) do
    do_handle("JOINBATTLE", "#{bnum} empty 193322681", state)
  end

  defp do_handle("OB", _, state) do
    do_handle("OPENBATTLE", "0 0 empty 322 16 gameHash 0 mapHash engineName\tengineVersion\tmapName\tgameTitle\tgameName", state)
  end

  # Specific handlers for different commands
  @spec do_handle(String.t(), String.t(), Map.t()) :: Map.t()
  defp do_handle("MYSTATUS", data, state) do
    case Regex.run(~r/([0-9]+)/, data) do
      [_, new_value] ->
        status_bits = BitParse.parse_bits(new_value, 7)
        [in_game, away, _r1, _r2, _r3, _mod, _bot] = status_bits

        new_client =
          Map.merge(state.client, %{
            in_game: in_game == 1,
            away: away == 1
          })

        # This just accepts it and updates the client
        new_client = Client.update(new_client, :client_updated_status)
        %{state | client: new_client}

      nil ->
        Logger.debug("[command:mystatus] bad match on: #{data}")
        state
    end
  end

  defp do_handle("LOGIN", data, state) do
    response =
      case Regex.run(~r/^(\S+) (\S+) (0) ([0-9\.\*]+) ([^\t]+)\t([^\t]+)\t([^\t]+)/, data) do
        [_, username, password, _cpu, ip, lobby, userid, modes] ->
          _ = [username, password, ip, lobby, userid, modes]
          username = User.clean_name(username)
          Logger.debug("[protocol:login] matched #{username}")
          User.try_login(username, password, state)

        nil ->
          new_data = data
          |> String.replace("\t", "~")
          |> String.replace(" ", "_")
          {:error, "Invalid details format, got #{new_data}"}
      end

    case response do
      # {:ok, %{verified: false} = _user} ->
      #   reason = "Account not verified"
      #   Logger.debug("[command:login] denied with reason #{reason}")
      #   _send("DENIED #{reason}\n", state)
      #   state

      {:ok, user} ->
        # Login the client
        client = Client.login(user, self(), __MODULE__)

        # Who is online?
        # skip ourselves because that will result in a double ADDUSER
        Client.list_client_ids()
        |> Enum.map(fn userid ->
          user = User.get_user_by_id(userid)
          reply(:add_user, user, state)
        end)
        :timer.sleep(100)

        # Client status messages
        Client.list_clients()
        |> Enum.map(fn client ->
          reply(:client_status, client, state)
        end)
        :timer.sleep(100)

        Battle.list_battles()
        |> Enum.each(fn b ->
          reply(:battle_opened, b, state)
          reply(:update_battle, b, state)
          reply(:battle_players, b, state)
        end)
        :timer.sleep(100)

        _send("LOGININFOEND\n", state)
        :ok = PubSub.subscribe(Central.PubSub, "all_battle_updates")
        :ok = PubSub.subscribe(Central.PubSub, "all_client_updates")
        :ok = PubSub.subscribe(Central.PubSub, "all_user_updates")
        :ok = PubSub.subscribe(Central.PubSub, "user_updates:#{user.id}")
        %{state | client: client, user: user, name: user.name, userid: user.id}

      {:error, reason} ->
        Logger.debug("[command:login] denied with reason #{reason}")
        _send("DENIED #{reason}\n", state)
        state
    end
  end

  defp do_handle("REGISTER", data, state) do
    case Regex.run(~r/(\S+) (\S+) (\S+)/, data) do
      [_, username, password_hash, email] ->
        case User.get_user_by_name(username) do
          nil ->
            User.register_user(username, email, password_hash)
            reply(:registration_accepted, state)

          _ ->
            reply(:registration_denied, "User already exists", state)
        end

      _ ->
        nil
    end

    state
  end

  # defp do_handle("CONFIRMAGREEMENT", code, state) do
  #   case  do
  #      ->

  #   end
  # end

  defp do_handle("RENAMEACCOUNT", new_name, state) do
    User.rename_user(state.user, new_name)
    _send("SERVERMSG Username changed, please log back in\n", state)
    send(self(), :terminate)
    state
  end

  defp do_handle("RESETPASSWORDREQUEST", email, state) do
    case state.user == nil or email == state.user.email do
      true ->
        user = User.get_user_by_email(email)

        case user do
          nil ->
            _send("RESETPASSWORDREQUESTDENIED error\n", state)

          _ ->
            User.request_password_reset(user)
            _send("RESETPASSWORDREQUESTACCEPTED\n", state)
        end

      false ->
        # They have requested a password reset for a different user?
        _send("RESETPASSWORDREQUESTDENIED error\n", state)
    end

    state
  end

  defp do_handle("RESETPASSWORD", data, state) do
    case Regex.run(~r/(\S+) (\S+)/, data) do
      [_, email, code] ->
        user = User.get_user_by_email(email)

        cond do
          user == nil ->
            _send("RESETPASSWORDDENIED no_user\n", state)

          user.password_reset_code == nil ->
            _send("RESETPASSWORDDENIED nil_code\n", state)

          state.userid != nil and state.userid != user.id ->
            _send("RESETPASSWORDDENIED wrong_user\n", state)

          true ->
            case User.reset_password(user, code) do
              :ok ->
                _send("RESETPASSWORDACCEPTED\n", state)

              :error ->
                _send("RESETPASSWORDDENIED wrong_code\n", state)
            end
        end

      _ ->
        nil
    end

    state
  end

  defp do_handle("CHANGEEMAILREQUEST", new_email, state) do
    new_user = User.request_email_change(state.user, new_email)

    case new_user do
      nil ->
        _send("CHANGEEMAILREQUESTDENIED no user\n", state)
        state

      _ ->
        _send("CHANGEEMAILREQUESTACCEPTED\n", state)
        %{state | user: new_user}
    end
  end

  defp do_handle("CHANGEEMAIL", data, state) do
    case Regex.run(~r/(\S+) (\S+)/, data) do
      [_, new_email, supplied_code] ->
        [correct_code, expected_email] = state.user.email_change_code

        cond do
          correct_code != supplied_code ->
            _send("CHANGEEMAILDENIED bad code\n", state)
            state

          new_email != expected_email ->
            _send("CHANGEEMAILDENIED bad email\n", state)
            state

          true ->
            new_user = User.change_email(state.user, new_email)
            _send("CHANGEEMAILACCEPTED\n", state)
            %{state | user: new_user}
        end

      _ ->
        state
    end
  end

  defp do_handle("EXIT", _reason, state) do
    Client.disconnect(state.userid)
    send(self(), :terminate)
    state
  end

  defp do_handle("GETUSERINFO", _, state) do
    # TODO: Actually have this information
    msg = [
      "SERVERMSG Registration date: Oct 21, 2020\n",
      "SERVERMSG Email address: #{state.user.email}\n",
      "SERVERMSG Ingame time: 3 hours\n"
    ]

    _send(msg, state)
    state
  end

  defp do_handle("CHANGEPASSWORD", data, state) do
    case Regex.run(~r/(\w+)\t(\w+)/, data) do
      [_, plain_old_password, plain_new_password] ->
        case User.test_password(
               User.encrypt_password(plain_old_password),
               state.user.password_hash
             ) do
          false ->
            _send("SERVERMSG Current password entered incorrectly\n", state)

          true ->
            encrypted_new_password = User.encrypt_password(plain_new_password)
            new_user = %{state.user | password_hash: encrypted_new_password}
            User.update_user(new_user)

            _send(
              "SERVERMSG Password changed, you will need to use it next time you login\n",
              state
            )
        end

      _ ->
        nil
    end

    state
  end

  # Friend list
  defp do_handle("FRIENDLIST", _, state), do: reply(:friendlist, state.user, state)
  defp do_handle("FRIENDREQUESTLIST", _, state), do: reply(:friendlist_request, state.user, state)

  defp do_handle("UNFRIEND", data, state) do
    [_, username] = String.split(data, "=")
    new_user = User.remove_friend(state.userid, User.get_userid(username))
    %{state | user: new_user}
  end

  defp do_handle("ACCEPTFRIENDREQUEST", data, state) do
    [_, username] = String.split(data, "=")
    new_user = User.accept_friend_request(User.get_userid(username), state.userid)
    %{state | user: new_user}
  end

  defp do_handle("DECLINEFRIENDREQUEST", data, state) do
    [_, username] = String.split(data, "=")
    new_user = User.decline_friend_request(User.get_userid(username), state.userid)
    %{state | user: new_user}
  end

  defp do_handle("FRIENDREQUEST", data, state) do
    [_, username] = String.split(data, "=")
    User.create_friend_request(state.userid, User.get_userid(username))
    state
  end

  defp do_handle("IGNORE", data, state) do
    [_, username] = String.split(data, "=")
    User.ignore_user(state.userid, User.get_userid(username))
    state
  end

  defp do_handle("UNIGNORE", data, state) do
    [_, username] = String.split(data, "=")
    User.unignore_user(state.userid, User.get_userid(username))
    state
  end

  defp do_handle("IGNORELIST", _, state), do: reply(:ignorelist, state.user, state)

  # Chat related
  defp do_handle("JOIN", data, state) do
    case Regex.run(~r/(\w+)(?:\t)?(\w+)?/, data) do
      [_, room_name] ->
        room = Room.get_or_make_room(room_name, state.userid)
        Room.add_user_to_room(state.userid, room_name)
        _send("JOIN #{room_name}\n", state)
        _send("JOINED #{room_name} #{state.name}\n", state)

        author_name = User.get_username(room.author_id)
        _send("CHANNELTOPIC #{room_name} #{author_name}\n", state)

        members = room.members
          |> Enum.map(fn m -> User.get_username(m) end)
          |> List.insert_at(0, state.name)
          |> Enum.join(" ")

        _send("CLIENTS #{room_name} #{members}\n", state)

        :ok = PubSub.subscribe(Central.PubSub, "room:#{room_name}")

      [_, room_name, _key] ->
        _send("JOINFAILED #{room_name} Locked\n", state)

      _ ->
        _send("JOINFAILED No match for details\n", state)
    end

    state
  end

  defp do_handle("LEAVE", room_name, state) do
    PubSub.unsubscribe(Central.PubSub, "room:#{room_name}")
    _send("LEFT #{room_name} #{state.name}\n", state)
    Room.remove_user_from_room(state.userid, room_name)
    state
  end

  defp do_handle("CHANNELS", _, state) do
    reply(:list_channels, state)
    state
  end

  defp do_handle("SAY", data, state) do
    case Regex.run(~r/(\w+) (.+)/, data) do
      [_, room_name, msg] ->
        Room.send_message(state.userid, room_name, msg)

      _ ->
        nil
    end

    state
  end

  defp do_handle("SAYPRIVATE", data, state) do
    case Regex.run(~r/(\w+) (.+)/, data) do
      [_, to_name, msg] ->
        User.send_direct_message(state.userid, User.get_userid(to_name), msg)
        _send("SAIDPRIVATE #{to_name} #{msg}\n", state)

      _ ->
        nil
    end

    state
  end

  # Battles
  # OPENBATTLE type natType password port maxPlayers gameHash rank mapHash {engineName} {engineVersion} {map} {title} {gameName}
  defp do_handle("OPENBATTLE", data, state) do
    response =
      case Regex.run(~r/^(\S+) (\S+) (\S+) (\S+) (\S+) (\S+) (\S+) (\S+) ([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.+)$/, data) do
        [_, type, nattype, _password, port, max_players, game_hash, _rank, map_hash, engine_name, engine_version, map_name, name, game_name] ->

          nattype =
            case nattype do
              "0" -> :none
              "1" -> :holepunch
              "2" -> :fixed
            end

          battle = %{
            founder_id: state.userid,
            founder_name: state.name,
            name: name,
            type: (if type == "0", do: :normal, else: :replay),
            nattype: nattype,
            port: port,
            max_players: int_parse(max_players),
            game_hash: game_hash,
            map_hash: map_hash,
            password: nil,
            rank: 0,
            locked: false,
            engine_name: engine_name,
            engine_version: engine_version,
            map_name: map_name,
            game_name: game_name
          }
          |> Battle.create_battle()
          |> Battle.add_battle()

          {:success, battle}

        nil ->
          {:failure, "No match"}
      end

    case response do
      {:success, battle} ->
        PubSub.subscribe(Central.PubSub, "battle_updates:#{battle.id}")
        Battle.add_user_to_battle(state.userid, battle.id)

        _send("OPENBATTLE #{battle.id}\n", state)
        reply(:join_battle, battle, state)
        reply(:add_script_tags, battle.tags, state)

        battle.start_rectangles
        |> Enum.each(fn r ->
          reply(:add_start_rectangle, r, state)
        end)

        _send("REQUESTBATTLESTATUS\n", state)

        new_client =
          Map.put(state.client, :battle_id, battle.id)
          |> Client.update()

        %{state | client: new_client}

      {:failure, reason} ->
        _send("OPENBATTLEFAILED #{reason}\n", state)
        state
    end
  end
  
  defp do_handle("JOINBATTLE", data, state) do
    response =
      case Regex.run(~r/^(\S+) (\S+) (\S+)$/, data) do
        [_, battleid, _password, _script_password] ->
          Battle.can_join?(state.user, battleid)

        nil ->
          {:failure, "Invalid details"}
      end

    case response do
      {:success, battle} ->
        Logger.debug("[command:joinbattle] success")
        PubSub.subscribe(Central.PubSub, "battle_updates:#{battle.id}")
        Battle.add_user_to_battle(state.userid, battle.id)
        reply(:join_battle, battle, state)
        reply(:add_script_tags, battle.tags, state)

        battle.players
        |> Enum.each(fn username ->
          client = Client.get_client(username)
          reply(:client_battlestatus, client, state)
        end)

        reply(:client_battlestatus, state.client, state)

        battle.start_rectangles
        |> Enum.each(fn r ->
          reply(:add_start_rectangle, r, state)
        end)

        _send("REQUESTBATTLESTATUS\n", state)

        # I think this is sent by SPADS but for now we're going to fake it
        _send(
          "SAIDBATTLEEX #{battle.founder_name} Hi #{state.name}! Current battle type is faked_team.\n",
          state
        )

        new_client =
          Map.put(state.client, :battle_id, battle.id)
          |> Client.update()

        %{state | client: new_client}

      {:failure, reason} ->
        Logger.debug("[command:joinbattle] denied with reason: #{reason}")
        _send("JOINBATTLEFAILED #{reason}\n", state)
        state
    end
  end
  
  defp do_handle("HANDICAP", data, state) do
    case Regex.run(~r/(\S+) (\d+)/, data) do
      [_, username, value] ->
        if Battle.allow?("HANDICAP", state) do
          clint_id = User.get_userid(username)
          client = Client.get_client(clint_id)
          # Can't update a client that doesn't exist
          if client != nil and client.battle_id == state.client.battle_id do
            client = %{client | handicap: int_parse(value)}
            Client.update(client, :client_updated_battlestatus)
          end
        end
      _ ->
        nil
    end
    state
  end
  
  defp do_handle("ADDSTARTRECT", data, state) do
    case Regex.run(~r/(\d+) (\d+) (\d+) (\d+) (\d+)/, data) do
      [_, team, left, top, right, bottom] ->
        if Battle.allow?("ADDSTARTRECT", state) do
          rectangle = int_parse([team, left, top, right, bottom])
          Battle.add_start_rectangle(state.client.battle_id, rectangle)
        end
      _ ->
        nil
    end
    state
  end

  defp do_handle("REMOVESTARTRECT", team, state) do
    if Battle.allow?("REMOVESTARTRECT", state) do
      team = int_parse(team)
      Battle.remove_start_rectangle(state.client.battle_id, team)
    end
    state
  end

  defp do_handle("SETSCRIPTTAGS", data, state) do
    if Battle.allow?("SETSCRIPTTAGS", state) do
      tags = data
        |> String.split("\t")
        |> Map.new(fn t ->
          [k, v] = String.split(t, "=")
          {String.downcase(k), v}
        end)

      Battle.set_script_tags(state.client.battle_id, tags)
    end
    state
  end

  defp do_handle("REMOVESCRIPTTAGS", data, state) do
    if Battle.allow?("SETSCRIPTTAGS", state) do
      keys = data
        |> String.downcase
        |> String.split("\t")

      Battle.remove_script_tags(state.client.battle_id, keys)
    end
    state
  end

  defp do_handle("KICKFROMBATTLE", data, state) do
    case Regex.run(~r/(\d+) (\S+)/, data) do
      [_, battle_id, username] ->
        if Battle.allow?("KICKFROMBATTLE", state) do
          userid = User.get_userid(username)
          Battle.kick_user_from_battle(userid, int_parse(battle_id))
        end
      _ ->
        nil
    end
    state
  end

  defp do_handle("FORCETEAMNO", data, state) do
    case Regex.run(~r/(\d+) (\S+)/, data) do
      [_, username, team_number] ->
        if Battle.allow?("FORCETEAMNO", state) do
          Client.force_status_change()
          Logger.error("TODO - Not implemented")
        end
      _ ->
        nil
    end
    state
  end

  defp do_handle("FORCEALLYNO", data, state) do
    case Regex.run(~r/(\d+) (\S+)/, data) do
      [_, username, team_number] ->
        if Battle.allow?("FORCEALLYNO", state) do
          Logger.error("TODO - Not implemented")
        end
      _ ->
        nil
    end
    state
  end

  defp do_handle("FORCETEAMCOLOR", data, state) do
    case Regex.run(~r/(\d+) (\S+)/, data) do
      [_, username, colour] ->
        if Battle.allow?("FORCETEAMCOLOR", state) do
          Logger.error("TODO - Not implemented")
        end
      _ ->
        nil
    end
    state
  end

  defp do_handle("FORCESPECTATORMODE", username, state) do
    if Battle.allow?("FORCESPECTATORMODE", state) do
      Logger.error("TODO - Not implemented")
    end
    state
  end

  defp do_handle("PROMOTE", _, %{client: %{battle_id: nil}} = state), do: state
  defp do_handle("PROMOTE", _, state) do
    Logger.info("PROMOTE is not handled at this time as Chobby has no way to handle it - TODO")
    state
  end

  # ADDBOT STAI(1) 4195458 0 STAI
  defp do_handle("ADDBOT", _msg, %{client: %{battle_id: nil}} = state), do: state
  defp do_handle("ADDBOT", data, state) do
    case Regex.run(~r/(\S+) (\d+) (\d+) (\S+)/, data) do
      [_, name, battlestatus, team_colour, ai_dll] ->
        if Battle.allow?("ADDBOT", state) do
          Battle.add_bot_to_battle(state.client.battle_id, state.userid, {name, battlestatus, team_colour, ai_dll})
        end
      _ ->
        nil
    end
    state
  end

  defp do_handle("UPDATEBOT", _msg, %{client: %{battle_id: nil}} = state), do: state
  defp do_handle("UPDATEBOT", data, state) do
    case Regex.run(~r/(\S+) (\d+) (\d+) (\S+)/, data) do
      [_, name, battlestatus, team_colour] ->
        if Battle.allow?("UPDATEBOT", state) do
          Battle.update_bot(state.client.battle_id, name, battlestatus, team_colour)
        end
      _ ->
        nil
    end
    state
  end

  defp do_handle("SAYBATTLE", _msg, %{client: %{battle_id: nil}} = state), do: state

  defp do_handle("SAYBATTLE", msg, state) do
    if Battle.allow?("SAYBATTLE", state) do
      Battle.say(state.userid, msg, state.client.battle_id)
    end
    state
  end

  defp do_handle("LEAVEBATTLE", _, %{client: %{battle_id: nil}} = state), do: state

  defp do_handle("LEAVEBATTLE", _, state) do
    PubSub.unsubscribe(Central.PubSub, "battle_updates:#{state.client.battle_id}")
    reply(:remove_user_from_battle, {state.userid, state.client.battle_id}, state)
    new_client = Client.leave_battle(state.userid)
    %{state | client: new_client}
  end

  # b0 = undefined (reserved for future use)
  # b1 = ready (0=not ready, 1=ready)
  # b2..b5 = team no. (from 0 to 15. b2 is LSB, b5 is MSB)
  # b6..b9 = ally team no. (from 0 to 15. b6 is LSB, b9 is MSB)
  # b10 = mode (0 = spectator, 1 = normal player)
  # b11..b17 = handicap (7-bit number. Must be in range 0..100). Note: Only host can change handicap values of the players in the battle (with HANDICAP command). These 7 bits are always ignored in this command. They can only be changed using HANDICAP command.
  # b18..b21 = reserved for future use (with pre 0.71 versions these bits were used for team color index)
  # b22..b23 = sync status (0 = unknown, 1 = synced, 2 = unsynced)
  # b24..b27 = side (e.g.: arm, core, tll, ... Side index can be between 0 and 15, inclusive)
  # b28..b31 = undefined (reserved for future use)
  defp do_handle("MYBATTLESTATUS", _, %{client: %{battle_id: nil}} = state), do: state

  defp do_handle("MYBATTLESTATUS", data, state) do
    new_client =
      case Regex.run(~r/(\S+) (.+)/, data) do
        [_, battlestatus, team_colour] ->
          status_bits = BitParse.parse_bits(battlestatus, 32)

          [
            _,
            ready,
            t1,
            t2,
            t3,
            t4,
            a1,
            a2,
            a3,
            a4,
            spectator,
            # Handicap, not set here
            _h1,
            _h2,
            _h3,
            _h4,
            _h5,
            _h6,
            _h7,
            _,
            _,
            _,
            _,
            sync1,
            sync2,
            side1,
            side2,
            side3,
            side4,
            _,
            _,
            _,
            _
          ] = status_bits

          new_client =
            Map.merge(state.client, %{
              ready: ready == 1,
              team_number: [t1, t2, t3, t4] |> Integer.undigits(2),
              ally_team_number: [a1, a2, a3, a4] |> Integer.undigits(2),
              spectator: spectator == 1,
              sync: [sync1, sync2] |> Integer.undigits(2),
              side: [side1, side2, side3, side4] |> Integer.undigits(2),
              team_colour: team_colour
            })

          # This one needs a bit more nuance, for now we'll wrap it in this
          if Battle.allow?("MYBATTLESTATUS", state) do
            Client.update(new_client, :client_updated_battlestatus)
          else
            state.client
          end

        _ ->
          state.client
      end

    Map.put(state, :client, new_client)
  end

  # MISC
  defp do_handle("PING", _, state) do
    _send("PONG\n", state)
    state
  end

  defp do_handle("RING", username, state) do
    userid = User.get_userid(username)
    User.ring(userid, state.userid)
    state
  end

  # Not handled cacther
  defp do_handle(nil, _, state), do: state

  defp do_handle(match, data, state) do
    Logger.error("No match for #{match}, #{data}")
    _send("ERR - No match\n", state)
    state
  end

  # Reply commands, these are things we are sending to the client
  # based on messages they sent us
  @spec reply(Atom.t(), nil | String.t() | Tuple.t() | List.t(), Map.t()) :: Map.t()
  def reply(reply_type, data, state) do
    msg = do_reply(reply_type, data)
    _send(msg, state)
    state
  end

  # Two argument version of the above, just means the data is nil
  @spec reply(Atom.t(), Map.t()) :: Map.t()
  def reply(reply_type, state), do: reply(reply_type, nil, state)

  @spec do_reply(Atom.t(), String.t() | List.t()) :: String.t()
  defp do_reply(:login_accepted, user) do
    "ACCEPTED #{user}\n"
  end

  defp do_reply(:motd, nil) do
    @motd
    |> String.split("\n")
    |> Enum.map(fn m -> "MOTD #{m}\n" end)
    |> Enum.join("")
  end

  defp do_reply(:add_user, user) do
    "ADDUSER #{user.name} #{user.country} #{user.id} #{user.lobbyid}\n"
  end

  defp do_reply(:remove_user, {_userid, username}) do
    "REMOVEUSER #{username}\n"
  end

  defp do_reply(:friendlist, user) do
    friends =
      user.friends
      |> Enum.map(fn f ->
        name = User.get_username(f)
        "FRIENDLIST userName=#{name}\n"
      end)

    (["FRIENDLISTBEGIN\n"] ++ friends ++ ["FRIENDLISTEND\n"])
    |> Enum.join("")
  end

  defp do_reply(:friendlist_request, user) do
    requests =
      user.friend_requests
      |> Enum.map(fn f ->
        name = User.get_username(f)
        "FRIENDREQUESTLIST userName=#{name}\n"
      end)

    (["FRIENDREQUESTLISTBEGIN\n"] ++ requests ++ ["FRIENDREQUESTLISTEND\n"])
    |> Enum.join("")
  end

  defp do_reply(:ignorelist, user) do
    ignored =
      user.ignored
      |> Enum.map(fn f ->
        name = User.get_username(f)
        "IGNORELIST userName=#{name}\n"
      end)

    (["IGNORELISTBEGIN\n"] ++ ignored ++ ["IGNORELISTEND\n"])
    |> Enum.join("")
  end

  # https://springrts.com/dl/LobbyProtocol/ProtocolDescription.html#BATTLEOPENED:server
  defp do_reply(:battle_opened, battle) when is_map(battle) do
    type =
      case battle.type do
        :normal -> 0
        :replay -> 1
      end

    nattype =
      case battle.nattype do
        :none -> 0
        :holepunch -> 1
        :fixed -> 2
      end

    passworded = if battle.password == nil, do: 0, else: 1

    "BATTLEOPENED #{battle.id} #{type} #{nattype} #{battle.founder_name} #{battle.ip} #{battle.port} #{
      battle.max_players
    } #{passworded} #{battle.rank} #{battle.map_hash} #{battle.engine_name}\t#{
      battle.engine_version
    }\t#{battle.map_name}\t#{battle.name}\t#{battle.game_name}\ttest-15386-5c98cfa\n"
  end

  defp do_reply(:battle_opened, battle_id) do
    do_reply(:battle_opened, Battle.get_battle(battle_id))
  end

  defp do_reply(:update_battle, battle) do
    locked = battle.locked == 1

    "UPDATEBATTLEINFO #{battle.id} #{battle.spectator_count} #{locked} #{battle.map_hash} #{
      battle.map_name
    }\n"
  end

  defp do_reply(:join_battle, battle) do
    "JOINBATTLE #{battle.id} #{battle.game_hash}\n"
  end

  defp do_reply(:add_start_rectangle, [team, left, top, right, bottom]) do
    "ADDSTARTRECT #{team} #{left} #{top} #{right} #{bottom}\n"
  end

  defp do_reply(:remove_start_rectangle, team) do
    "REMOVESTARTRECT #{team}\n"
  end

  defp do_reply(:add_script_tags, tags) do
    tags = tags
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
      |> Enum.join("\t")

    "SETSCRIPTTAGS " <> tags <> "\n"
  end

  defp do_reply(:remove_script_tags, keys) do
    "REMOVESCRIPTTAGS " <> Enum.join(keys, "\t") <> "\n"
  end

  defp do_reply(:add_bot_to_battle, {battle_id, bot}) do
    "ADDBOT #{battle_id} #{bot.name} #{bot.owner_name} #{bot.battlestatus} #{bot.team_colour} #{bot.ai_dll}\n"
  end

  defp do_reply(:update_bot, {battle_id, bot}) do
    "UPDATEBOT #{battle_id} #{bot.name} #{bot.owner_name} #{bot.battlestatus} #{bot.team_colour}\n"
  end

  defp do_reply(:battle_players, battle) do
    battle.players
    |> Parallel.map(fn player_id ->
      pname = User.get_username(player_id)
      "JOINEDBATTLE #{battle.id} #{pname}\n"
    end)
  end

  defp do_reply(:close_battle, battle) do
    "BATTLECLOSED #{battle.id}\n"
  end

  # Client
  defp do_reply(:registration_accepted, nil) do
    "REGISTRATIONACCEPTED\n"
  end

  defp do_reply(:registration_denied, reason) do
    "REGISTRATIONDENIED #{reason}\n"
  end

  defp do_reply(:client_status, client) do
    "CLIENTSTATUS #{client.name} #{client.status}\n"
  end

  defp do_reply(:client_battlestatus, {userid, battlestatus, team_colour}) do
    name = User.get_username(userid)
    "CLIENTBATTLESTATUS #{name} #{battlestatus} #{team_colour}\n"
  end

  defp do_reply(:client_battlestatus, client) do
    "CLIENTBATTLESTATUS #{client.name} #{client.battlestatus} #{client.team_colour}\n"
  end

  defp do_reply(:logged_in_client, {userid, _username}) do
    user = User.get_user_by_id(userid)
    do_reply(:add_user, user)
  end

  defp do_reply(:logged_out_client, {userid, username}) do
    do_reply(:remove_user, {userid, username})
  end

  # Commands
  defp do_reply(:ring, {ringer_id, state_user}) do
    if ringer_id not in (state_user.ignored || []) do
      ringer_name = User.get_username(ringer_id)
      "RING #{ringer_name}\n"
    end
  end

  # Chat
  defp do_reply(:list_channels, nil) do
    channels =
      Room.list_rooms()
      |> Enum.map(fn room ->
        "CHANNEL #{room.name} #{Enum.count(room.members)}\n"
      end)

    (["CHANNELS\n"] ++ channels ++ ["ENDOFCHANNELS\n"])
    |> Enum.join("")
  end

  defp do_reply(:direct_message, {from_id, msg, state_user}) do
    if from_id not in (state_user.ignored || []) do
      from_name = User.get_username(from_id)
      "SAIDPRIVATE #{from_name} #{msg}\n"
    end
  end

  defp do_reply(:chat_message, {from_id, room_name, msg, state_user}) do
    if from_id not in (state_user.ignored || []) do
      from_name = User.get_username(from_id)
      "SAID #{room_name} #{from_name} #{msg}\n"
    end
  end

  defp do_reply(:add_user_to_room, {userid, room_name}) do
    username = User.get_username(userid)
    "JOINED #{room_name} #{username}\n"
  end

  # Battle
  defp do_reply(:remove_user_from_room, {userid, room_name}) do
    username = User.get_username(userid)
    "LEFT #{room_name} #{username}\n"
  end

  defp do_reply(:add_user_to_battle, {userid, battleid}) do
    username = User.get_username(userid)
    "JOINEDBATTLE #{battleid} #{username}\n"
  end

  defp do_reply(:remove_user_from_battle, {userid, battleid}) do
    username = User.get_username(userid)
    "LEFTBATTLE #{battleid} #{username}\n"
  end

  defp do_reply(:forcequit_battle, nil) do
    "FORCEQUITBATTLE\n"
  end

  defp do_reply(:battle_message, {userid, msg, _battle_id}) do
    username = User.get_username(userid)
    "SAIDBATTLE #{username} #{msg}\n"
  end

  defp do_reply(:battle_saidex, {userid, msg, _battle_id}) do
    username = User.get_username(userid)
    "SAIDBATTLEEX #{username} #{msg}\n"
  end

  defp do_reply(atom, data) do
    Logger.error("No match in spring.ex for atom: #{atom} and data: #{Kernel.inspect data}")
    ""
  end

  # Sends a message to the client. The function takes into account message ID and well warn if a message without a newline ending is sent.
  defp _send(msg, state) do
    _send(msg, state.socket, state.transport, state.msg_id)
  end

  defp _send(nil, _, _, _), do: nil
  defp _send("", _, _, _), do: nil
  defp _send([], _, _, _), do: nil

  defp _send(msg, socket, transport, msg_id) when is_list(msg) do
    _send(Enum.join(msg, ""), socket, transport, msg_id)
  end

  defp _send(msg, socket, transport, msg_id) do
    # If no line return at the end we should warn about that
    # I've made the mistake of forgetting it and wondering
    # why stuff wasn't working so it's staying here
    if not String.ends_with?(msg, "\n") do
      Logger.warn("Attempting to send message without newline at the end - #{msg}")
    end

    msg =
      if msg_id != "" and msg_id != nil do
        msg
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(fn m -> "#{msg_id} #{m}\n" end)
        |> Enum.join("")
      else
        msg
      end

    Logger.info("--> #{Kernel.inspect(socket)} #{TcpServer.format_log(msg)}")
    transport.send(socket, msg)
  end
end
