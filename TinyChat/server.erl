-module(server).

-export([start_server/0]).

-include_lib("./defs.hrl").

-spec start_server() -> _.
-spec loop(_State) -> _.
-spec do_join(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_leave(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_new_nick(_State, _Ref, _ClientPID, _NewNick) -> _.
-spec do_client_quit(_State, _Ref, _ClientPID) -> _NewState.

start_server() ->
    catch(unregister(server)),
    register(server, self()),
    case whereis(testsuite) of
	undefined -> ok;
	TestSuitePID -> TestSuitePID!{server_up, self()}
    end,
    loop(
      #serv_st{
	 nicks = maps:new(), %% nickname map. client_pid => "nickname"
	 registrations = maps:new(), %% registration map. "chat_name" => [client_pids]
	 chatrooms = maps:new() %% chatroom map. "chat_name" => chat_pid
	}
     ).

loop(State) ->
    receive 
	%% initial connection
	{ClientPID, connect, ClientNick} ->
	    NewState =
		#serv_st{
		   nicks = maps:put(ClientPID, ClientNick, State#serv_st.nicks),
		   registrations = State#serv_st.registrations,
		   chatrooms = State#serv_st.chatrooms
		  },
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, join, ChatName} ->
	    NewState = do_join(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, leave, ChatName} ->
	    NewState = do_leave(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to register a new nickname
	{ClientPID, Ref, nick, NewNick} ->
	    NewState = do_new_nick(State, Ref, ClientPID, NewNick),
	    loop(NewState);
	%% client requests to quit
	{ClientPID, Ref, quit} ->
	    NewState = do_client_quit(State, Ref, ClientPID),
	    loop(NewState);
	{TEST_PID, get_state} ->
	    TEST_PID!{get_state, State},
	    loop(State)
    end.

%% executes join protocol from server perspective
do_join(ChatName, ClientPID, Ref, State) ->
    case lists:member(ChatName, maps:keys(State#serv_st.registrations)) of
	false -> ChatroomPID = spawn(chatroom, start_chatroom, [ChatName]),
		 {ok, ClientNick} = maps:find(ClientPID, State#serv_st.nicks),
		 ChatroomPID!{self(), Ref, register, ClientPID, ClientNick},
		New_State = #serv_st{nicks = State#serv_st.nicks,
		 	 registrations = maps:put(ChatName, [ClientPID], State#serv_st.registrations),
			 chatrooms = maps:put(ChatName, ChatroomPID, State#serv_st.chatrooms)},
		New_State;
	true -> {ok, ChatroomPID} = maps:find(ChatName, State#serv_st.chatrooms),
		{ok, ClientNick} = maps:find(ClientPID, State#serv_st.nicks),
		ChatroomPID!{self(), Ref, register, ClientPID, ClientNick},
		{ok, Pids} = maps:find(ChatName, State#serv_st.registrations),
		New_State = #serv_st{nicks = State#serv_st.nicks,
		 	 registrations = maps:put(ChatName, [ClientPID]++Pids, State#serv_st.registrations),
			 chatrooms = State#serv_st.chatrooms},
		New_State
	end.	

%% executes leave protocol from server perspective
do_leave(ChatName, ClientPID, Ref, State) ->
	{ok, ChatPID} = maps:find(ChatName, State#serv_st.chatrooms),
	{ok, Pids} = maps:find(ChatName, State#serv_st.registrations),
	New_State = #serv_st{nicks = State#serv_st.nicks,
		 	 registrations = maps:put(ChatName, Pids--[ClientPID], State#serv_st.registrations),
			 chatrooms = State#serv_st.chatrooms},
	ChatPID!{self(), Ref, unregister, ClientPID},
	ClientPID!{self(), Ref, ack_leave},
	New_State.

%% notify chatrooms that client has changed name
new_nick_chat(State, All_chats, NewNick, ClientPID, Ref) ->
	case All_chats of 
		[H|T] -> {ok, ClientList} = maps:find(H, State#serv_st.registrations),
			case lists:member(ClientPID, ClientList) of 
				true ->  {ok, ChatroomPID} = maps:find(H, State#serv_st.chatrooms),
						ChatroomPID!{self(), Ref, update_nick, ClientPID, NewNick},
			 			new_nick_chat(State, T, NewNick, ClientPID, Ref);
				false -> new_nick_chat(State, T, NewNick, ClientPID, Ref) end;					 
		[] ->  [] end.

%% executes new nickname protocol from server perspective
do_new_nick(State, Ref, ClientPID, NewNick) ->    
    case lists:member(NewNick, maps:values(State#serv_st.nicks)) of
	true -> ClientPID!{self(),Ref,err_nick_used}, State;
	false -> new_nick_chat(State, maps:keys(State#serv_st.registrations), NewNick, ClientPID, Ref),
		New_State = #serv_st{nicks = maps:update(ClientPID, NewNick, State#serv_st.nicks),
		 	 registrations = State#serv_st.registrations,
			 chatrooms = State#serv_st.chatrooms},
		ClientPID!{self(),Ref,ok_nick}, 
		New_State
	end.

%% notify chatrooms that client has left
client_leave(State, All_chats, ClientPID, Ref) ->
	case All_chats of 
		[H|T] -> {ok, ClientList} = maps:find(H, State#serv_st.registrations),
			case lists:member(ClientPID, ClientList) of 
				true ->  {ok, ChatroomPID} = maps:find(H, State#serv_st.chatrooms),
						ChatroomPID!{self(), Ref, unregister, ClientPID},
			 			client_leave(State, T, ClientPID, Ref);
				false -> client_leave(State, T, ClientPID, Ref) end;					 
		[] ->  [] end.

%% fix the registrations 
fix_registrations(Listings, ClientPID) ->
	case Listings of
		[{ChatName, ClientList}|T] -> 
			[{ChatName, lists:delete(ClientPID, ClientList)}] ++ fix_registrations(T, ClientPID);
		[] -> [] end.
		
%% executes client quit protocol from server perspective
do_client_quit(State, Ref, ClientPID) ->
    New_State = #serv_st{nicks = maps:remove(ClientPID, State#serv_st.nicks),
		 	 registrations = maps:from_list(fix_registrations(maps:to_list(State#serv_st.registrations), ClientPID)),
			 chatrooms = State#serv_st.chatrooms},
	client_leave(State, maps:keys(State#serv_st.registrations), ClientPID, Ref),
	ClientPID!{self(), Ref, ack_quit}.
