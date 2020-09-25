%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_exproto_channel).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("emqx/include/types.hrl").
-include_lib("emqx/include/logger.hrl").

-logger_header("[ExProto Channel]").

-export([ info/1
        , info/2
        , stats/1
        ]).

-export([ init/2
        , handle_in/2
        , handle_deliver/2
        , handle_timeout/3
        , handle_call/2
        , handle_cast/2
        , handle_info/2
        , terminate/2
        ]).

-export_type([channel/0]).

-record(channel, {
          %% gRPC channel options
          gcli :: map(),
          %% Conn info
          conninfo :: emqx_types:conninfo(),
          %% Client info from `register` function
          clientinfo :: maybe(map()),
          %% Registered
          authorized = false :: boolean(),
          %% Connection state
          conn_state :: conn_state(),
          %% Subscription
          subscriptions = #{},
          %% Request queue
          rqueue = queue:new(),
          %% Inflight function name
          inflight = undefined
         }).

-opaque(channel() :: #channel{}).

-type(conn_state() :: idle | connecting | connected | disconnected).

-type(reply() :: {outgoing, binary()}
               | {outgoing, [binary()]}
               | {close, Reason :: atom()}).

-type(replies() :: emqx_types:packet() | reply() | [reply()]).

-define(INFO_KEYS, [conninfo, conn_state, clientinfo, session, will_msg]).

-define(SESSION_STATS_KEYS,
        [subscriptions_cnt,
         subscriptions_max,
         inflight_cnt,
         inflight_max,
         mqueue_len,
         mqueue_max,
         mqueue_dropped,
         next_pkt_id,
         awaiting_rel_cnt,
         awaiting_rel_max
        ]).

%%--------------------------------------------------------------------
%% Info, Attrs and Caps
%%--------------------------------------------------------------------

%% @doc Get infos of the channel.
-spec(info(channel()) -> emqx_types:infos()).
info(Channel) ->
    maps:from_list(info(?INFO_KEYS, Channel)).

-spec(info(list(atom())|atom(), channel()) -> term()).
info(Keys, Channel) when is_list(Keys) ->
    [{Key, info(Key, Channel)} || Key <- Keys];
info(conninfo, #channel{conninfo = ConnInfo}) ->
    ConnInfo;
info(clientid, #channel{clientinfo = ClientInfo}) ->
    maps:get(clientid, ClientInfo, undefined);
info(clientinfo, #channel{clientinfo = ClientInfo}) ->
    ClientInfo;
info(session, #channel{subscriptions = Subs,
                       conninfo = ConnInfo}) ->
    #{subscriptions => Subs,
      upgrade_qos => false,
      retry_interval => 0,
      await_rel_timeout => 0,
      created_at => maps:get(connected_at, ConnInfo)};
info(conn_state, #channel{conn_state = ConnState}) ->
    ConnState;
info(will_msg, _) ->
    undefined.

-spec(stats(channel()) -> emqx_types:stats()).
stats(#channel{subscriptions = Subs}) ->
    [{subscriptions_cnt, maps:size(Subs)},
     {subscriptions_max, 0},
     {inflight_cnt, 0},
     {inflight_max, 0},
     {mqueue_len, 0},
     {mqueue_max, 0},
     {mqueue_dropped, 0},
     {next_pkt_id, 0},
     {awaiting_rel_cnt, 0},
     {awaiting_rel_max, 0}].

%%--------------------------------------------------------------------
%% Init the channel
%%--------------------------------------------------------------------

-spec(init(emqx_exproto_types:conninfo(), proplists:proplist()) -> channel()).
init(ConnInfo = #{socktype := Socktype,
                  peername := Peername,
                  sockname := Sockname,
                  peercert := Peercert}, Options) ->
    GRpcChann = proplists:get_value(handler, Options),
    NConnInfo = default_conninfo(ConnInfo),
    ClientInfo = default_clientinfo(ConnInfo),
    Channel = #channel{gcli = #{channel => GRpcChann},
                       conninfo = NConnInfo,
                       clientinfo = ClientInfo,
                       conn_state = connecting},

    Req = #{conninfo =>
            peercert(Peercert,
                     #{socktype => socktype(Socktype),
                       peername => address(Peername),
                       sockname => address(Sockname)})},
    try_dispatch(on_socket_created, wrap(Req), Channel).

%% @private
peercert(nossl, ConnInfo) ->
    ConnInfo;
peercert(Peercert, ConnInfo) ->
    ConnInfo#{peercert =>
              #{cn => esockd_peercert:common_name(Peercert),
                dn => esockd_peercert:subject(Peercert)}}.

%% @private
socktype(tcp) -> 'TCP';
socktype(ssl) -> 'SSL';
socktype(udp) -> 'UDP';
socktype(dtls) -> 'DTLS'.

%% @private
address({Host, Port}) ->
    #{host => inet:ntoa(Host), port => Port}.

%%--------------------------------------------------------------------
%% Handle incoming packet
%%--------------------------------------------------------------------

-spec(handle_in(binary(), channel())
      -> {ok, channel()}
       | {shutdown, Reason :: term(), channel()}).
handle_in(Data, Channel) ->
    Req = #{bytes => Data},
    {ok, try_dispatch(on_received_bytes, wrap(Req), Channel)}.

-spec(handle_deliver(list(emqx_types:deliver()), channel())
      -> {ok, channel()}
       | {shutdown, Reason :: term(), channel()}).
handle_deliver(Delivers, Channel) ->
    %% TODO: ?? Nack delivers from shared subscriptions
    Msgs = [ #{node => atom_to_binary(node(), utf8),
               id => hexstr(emqx_message:id(Msg)),
               qos => emqx_message:qos(Msg),
               from => fmt_from(emqx_message:from(Msg)),
               topic => emqx_message:topic(Msg),
               payload => emqx_message:payload(Msg),
               timestamp => emqx_message:timestamp(Msg)
              } || {_, _, Msg} <- Delivers],
    Req = #{messages => Msgs},
    {ok, try_dispatch(on_received_messages, wrap(Req), Channel)}.

-spec(handle_timeout(reference(), Msg :: term(), channel())
      -> {ok, channel()}
       | {shutdown, Reason :: term(), channel()}).
handle_timeout(_TRef, Msg, Channel) ->
    ?WARN("Unexpected timeout: ~p", [Msg]),
    {ok, Channel}.

-spec(handle_call(any(), channel())
     -> {reply, Reply :: term(), channel()}
      | {reply, Reply :: term(), replies(), channel()}
      | {shutdown, Reason :: term(), Reply :: term(), channel()}).

handle_call({send, Data}, Channel) ->
    {reply, ok, [{outgoing, Data}], Channel};

handle_call(close, Channel) ->
    {reply, ok, [{close, normal}], Channel};

handle_call({auth, ClientInfo, _Password}, Channel = #channel{authorized = true}) ->
    ?LOG(warning, "Duplicated authorized command, dropped ~p", [ClientInfo]),
    {ok, {error, already_authorized}, Channel};
handle_call({auth, ClientInfo0, Password},
            Channel = #channel{conninfo = ConnInfo,
                               clientinfo = ClientInfo}) ->
    ClientInfo1 = maybe_assign_clientid(ClientInfo0),
    ClientInfo2 = enrich_clientinfo(ClientInfo1, ClientInfo),
    NConnInfo = enrich_conninfo(ClientInfo2, ConnInfo),

    Channel1 = Channel#channel{conninfo = NConnInfo,
                               clientinfo = ClientInfo2},

    #{clientid := ClientId, username := Username} = ClientInfo2,

    case emqx_access_control:authenticate(ClientInfo2#{password => Password}) of
        {ok, AuthResult} ->
            is_anonymous(AuthResult) andalso
                emqx_metrics:inc('client.auth.anonymous'),
            NClientInfo = maps:merge(ClientInfo2, AuthResult),
            NChannel = Channel1#channel{authorized = true,
                                        clientinfo = NClientInfo},
            case emqx_cm:open_session(true, NClientInfo, NConnInfo) of
                {ok, _Session} ->
                    {reply, ok, [{event, authorized}], NChannel};
                {error, Reason} ->
                    ?LOG(warning, "Client ~s (Username: '~s') open session failed for ~0p",
                         [ClientId, Username, Reason]),
                    {shutdown, Reason, {error, Reason}, NChannel}
            end;
        {error, Reason} ->
            ?LOG(warning, "Client ~s (Username: '~s') login failed for ~0p",
                 [ClientId, Username, Reason]),
            {shutdown, Reason, {error, Reason}, Channel1}
    end;

handle_call({subscribe, TopicFilter, Qos}, Channel) ->
    {ok, NChannel} = do_subscribe([{TopicFilter, #{qos => Qos}}], Channel),
    {reply, ok, NChannel};

handle_call({unsubscribe, TopicFilter}, Channel) ->
    {ok, NChannel} = do_unsubscribe([{TopicFilter, #{}}], Channel),
    {reply, ok, NChannel};

handle_call({publish, Topic, Qos, Payload},
            Channel = #channel{clientinfo = #{clientid := From,
                                              mountpoint := Mountpoint}}) ->
    Msg = emqx_message:make(From, Qos, Topic, Payload),
    NMsg = emqx_mountpoint:mount(Mountpoint, Msg),
    emqx:publish(NMsg),
    {reply, ok, Channel};

handle_call(kick, Channel) ->
    {shutdown, kicked, ok, Channel};

handle_call(Req, Channel) ->
    ?WARN("Unexpected call: ~p", [Req]),
    {reply, ok, Channel}.

-spec(handle_cast(any(), channel())
     -> {ok, channel()}
      | {ok, replies(), channel()}
      | {shutdown, Reason :: term(), channel()}).
handle_cast(Req, Channel) ->
    ?WARN("Unexpected call: ~p", [Req]),
    {ok, Channel}.

-spec(handle_info(any(), channel())
      -> {ok, channel()}
       | {shutdown, Reason :: term(), channel()}).
handle_info({subscribe, TopicFilters}, Channel) ->
    do_subscribe(TopicFilters, Channel);

handle_info({unsubscribe, TopicFilters}, Channel) ->
    do_unsubscribe(TopicFilters, Channel);

handle_info({sock_closed, Reason}, Channel) ->
    {shutdown, {sock_closed, Reason}, Channel};

handle_info({hreply, on_socket_created, {ok, _}}, Channel) ->
    {ok, try_dispatch(Channel#channel{inflight = undefined, conn_state = connected})};
handle_info({hreply, FunName, {ok, _}}, Channel)
  when FunName == on_socket_closed;
       FunName == on_received_bytes;
       FunName == on_received_messages ->
    {ok, try_dispatch(Channel#channel{inflight = undefined})};
handle_info({hreply, FunName, {error, Reason}}, Channel) ->
    {shutdown, {error, {FunName, Reason}}, Channel};

handle_info(Info, Channel) ->
    ?WARN("Unexpected info: ~p", [Info]),
    {ok, Channel}.

-spec(terminate(any(), channel()) -> channel()).
terminate(Reason, Channel) ->
    Req = #{reason => stringfy(Reason)},
    try_dispatch(on_socket_closed, wrap(Req), Channel).

is_anonymous(#{anonymous := true}) -> true;
is_anonymous(_AuthResult)          -> false.

%%--------------------------------------------------------------------
%% Sub/UnSub
%%--------------------------------------------------------------------

do_subscribe(TopicFilters, Channel) ->
    NChannel = lists:foldl(
        fun({TopicFilter, SubOpts}, ChannelAcc) ->
            do_subscribe(TopicFilter, SubOpts, ChannelAcc)
        end, Channel, parse_topic_filters(TopicFilters)),
    {ok, NChannel}.

%% @private
do_subscribe(TopicFilter, SubOpts, Channel =
             #channel{clientinfo = ClientInfo = #{mountpoint := Mountpoint},
                      subscriptions = Subs}) ->
    NTopicFilter = emqx_mountpoint:mount(Mountpoint, TopicFilter),
    NSubOpts = maps:merge(?DEFAULT_SUBOPTS, SubOpts),
    SubId = maps:get(clientid, ClientInfo, undefined),
    _ = emqx:subscribe(NTopicFilter, SubId, NSubOpts),
    Channel#channel{subscriptions = Subs#{NTopicFilter => SubOpts}}.

do_unsubscribe(TopicFilters, Channel) ->
    NChannel = lists:foldl(
        fun({TopicFilter, SubOpts}, ChannelAcc) ->
            do_unsubscribe(TopicFilter, SubOpts, ChannelAcc)
        end, Channel, parse_topic_filters(TopicFilters)),
    {ok, NChannel}.

%% @private
do_unsubscribe(TopicFilter, _SubOpts, Channel =
               #channel{clientinfo = #{mountpoint := Mountpoint},
                        subscriptions = Subs}) ->
    TopicFilter1 = emqx_mountpoint:mount(Mountpoint, TopicFilter),
    _ = emqx:unsubscribe(TopicFilter1),
    Channel#channel{subscriptions = maps:remove(TopicFilter1, Subs)}.

%% @private
parse_topic_filters(TopicFilters) ->
    lists:map(fun emqx_topic:parse/1, TopicFilters).

%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------

wrap(Req) ->
     Req#{conn => pid_to_list(self())}.

try_dispatch(Channel = #channel{rqueue = Queue,
                                inflight = undefined,
                                gcli = GClient}) ->
    case queue:out(Queue) of
        {empty, _} ->
            Channel;
        {{value, {FunName, Req}}, NQueue} ->
            emqx_exproto_gcli:async_call(FunName, Req, GClient),
            Channel#channel{inflight = FunName, rqueue = NQueue}
    end.

try_dispatch(FunName, Req, Channel = #channel{inflight = undefined, gcli = GClient}) ->
    emqx_exproto_gcli:async_call(FunName, Req, GClient),
    Channel#channel{inflight = FunName};
try_dispatch(FunName, Req, Channel = #channel{rqueue = Queue}) ->
    Channel#channel{rqueue = queue:in({FunName, Req}, Queue)}.

%%--------------------------------------------------------------------
%% Format
%%--------------------------------------------------------------------

maybe_assign_clientid(ClientInfo) ->
    case maps:get(clientid, ClientInfo, undefined) of
        undefined ->
            ClientInfo#{clientid => emqx_guid:to_base62(emqx_guid:gen())};
        _ ->
            ClientInfo
    end.

enrich_conninfo(InClientInfo, ConnInfo) ->
    maps:merge(ConnInfo, maps:with([proto_name, proto_ver, clientid, username, keepalive], InClientInfo)).

enrich_clientinfo(InClientInfo = #{proto_name := ProtoName}, ClientInfo) ->
    NClientInfo = maps:merge(ClientInfo, maps:with([clientid, username, mountpoint], InClientInfo)),
    NClientInfo#{protocol => lowcase_atom(ProtoName)}.

default_conninfo(ConnInfo) ->
    ConnInfo#{proto_name => undefined,
              proto_ver => undefined,
              clean_start => true,
              clientid => undefined,
              username => undefined,
              conn_props => [],
              connected => true,
              connected_at => erlang:system_time(millisecond),
              keepalive => undefined,
              receive_maximum => 0,
              expiry_interval => 0}.

default_clientinfo(#{peername := {PeerHost, _},
                     sockname := {_, SockPort}}) ->
    #{zone         => external,
      protocol     => undefined,
      peerhost     => PeerHost,
      sockport     => SockPort,
      clientid     => undefined,
      username     => undefined,
      is_bridge    => false,
      is_superuser => false,
      mountpoint   => undefined}.

stringfy(Reason) ->
    unicode:characters_to_binary((io_lib:format("~0p", [Reason]))).

lowcase_atom(undefined) ->
    undefined;
lowcase_atom(S) ->
    binary_to_atom(string:lowercase(S), utf8).

hexstr(Bin) ->
    [io_lib:format("~2.16.0B",[X]) || <<X:8>> <= Bin].

fmt_from(undefined) -> <<>>;
fmt_from(Bin) when is_binary(Bin) -> Bin;
fmt_from(T) -> stringfy(T).
