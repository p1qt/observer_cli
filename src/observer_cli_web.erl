-module(observer_cli_web).

-include("observer_cli.hrl").

%% API
-export([start/0, start/1, start/2, stop/0]).

%% Cowboy callbacks
-export([
    init/2,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    terminate/3
]).

-define(DEFAULT_PORT, 8080).

-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    start([]).

-spec start(list() | integer()) -> {ok, pid()} | {error, term()}.
start(Port) when is_integer(Port) ->
    start([{port, Port}]);
start(Options) when is_list(Options) ->
    application:ensure_all_started(cowboy),
    Port = proplists:get_value(port, Options, ?DEFAULT_PORT),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/", cowboy_static, {priv_file, observer_cli, "index.html"}},
            {"/assets/xterm.js", cowboy_static, {priv_file, observer_cli, "assets/xterm.js"}},
            {"/assets/xterm-addon-fit.js", cowboy_static,
                {priv_file, observer_cli, "assets/xterm-addon-fit.js"}},
            {"/assets/xterm.css", cowboy_static, {priv_file, observer_cli, "assets/xterm.css"}},
            {"/ws", ?MODULE, []}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(
        observer_cli_web_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),
    io:format("Observer CLI web interface started on http://localhost:~p~n", [Port]),
    {ok, self()}.

-spec start(node(), list()) -> {ok, pid()} | {error, term()}.
start(Node, Options) when is_atom(Node), is_list(Options) ->
    case net_kernel:connect_node(Node) of
        true ->
            start([{remote_node, Node} | Options]);
        false ->
            {error, {cannot_connect, Node}}
    end.

-spec stop() -> ok.
stop() ->
    cowboy:stop_listener(observer_cli_web_listener),
    ok.

%% Cowboy callbacks

-spec init(cowboy_req:req(), any()) -> {cowboy_websocket, cowboy_req:req(), any(), map()}.
init(Req, State) ->
    {cowboy_websocket, Req, State, #{
        idle_timeout => 60000
    }}.

-spec websocket_init(any()) -> {ok, map()}.
websocket_init(_State) ->
    process_flag(trap_exit, true),
    Self = self(),

    put(input_buffer, []),
    put(cmd_buffer, []),

    Self ! {output, "\x1b[1;34mObserver CLI Web Interface\x1b[0m\r\n\r\n"},

    ObserverPid = spawn_link(fun() ->
        group_leader(Self, self()),
        observer_cli:start()
    end),

    {ok, #{observer_pid => ObserverPid}}.

-spec websocket_handle(any(), map()) -> {ok, map()} | {reply, any(), map()}.
websocket_handle({text, Data}, State) ->
    CmdBuffer =
        case get(cmd_buffer) of
            undefined -> [];
            Buffer -> Buffer
        end,

    case Data of
        <<13>> ->
            Input = CmdBuffer ++ "\n",
            InputBuffer = get(input_buffer),
            put(input_buffer, InputBuffer ++ [Input]),

            put(cmd_buffer, []),

            {reply, {text, "\r\n"}, State};
        <<8>> ->
            case CmdBuffer of
                [] ->
                    {ok, State};
                _ ->
                    NewCmdBuffer = lists:sublist(CmdBuffer, 1, length(CmdBuffer) - 1),
                    put(cmd_buffer, NewCmdBuffer),
                    {reply, {text, <<8, 32, 8>>}, State}
            end;
        _ ->
            CharInput = binary_to_list(Data),
            NewCmdBuffer = CmdBuffer ++ CharInput,
            put(cmd_buffer, NewCmdBuffer),
            {reply, {text, Data}, State}
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

-spec websocket_info(any(), map()) -> {ok, map()} | {reply, any(), map()}.
websocket_info({io_request, From, ReplyAs, Request}, State) ->
    Reply = handle_io_request(Request, self()),
    From ! {io_reply, ReplyAs, Reply},
    {ok, State};
websocket_info({output, Data}, State) ->
    {reply, {text, Data}, State};
websocket_info({'EXIT', Pid, _Reason}, State = #{observer_pid := Pid}) ->
    {reply, {text, <<"Observer process exited">>}, State};
websocket_info(_Info, State) ->
    {ok, State}.

-spec terminate(any(), cowboy_req:req(), map()) -> ok.
terminate(_Reason, _Req, #{observer_pid := Pid}) ->
    exit(Pid, kill),
    ok;
terminate(_Reason, _Req, _State) ->
    ok.

%% Internal functions

handle_io_request({put_chars, _Encoding, Chars}, WebSocketPid) ->
    WebSocketPid ! {output, Chars},
    ok;
handle_io_request({put_chars, _Encoding, Module, Function, Args}, WebSocketPid) ->
    try
        Chars = apply(Module, Function, Args),
        WebSocketPid ! {output, Chars},
        ok
    catch
        _:_ ->
            ok
    end;
handle_io_request({get_line, _Encoding, _Prompt}, _) ->
    case get(input_buffer) of
        [Input | Rest] ->
            put(input_buffer, Rest),
            case lists:suffix("\n", Input) of
                true -> Input;
                false -> Input ++ "\n"
            end;
        _ ->
            ""
    end;
handle_io_request(_, _) ->
    {error, request}.
