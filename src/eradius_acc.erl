-module(eradius_acc).
%%%-------------------------------------------------------------------
%%% File    : eradius_acc.erl
%%% Author  : Torbjorn Tornkvist <tobbe@bluetail.com>
%%% Desc    : RADIUS accounting.
%%% Created :  9 Apr 2003 by Torbjorn Tornkvist <tobbe@bluetail.com>
%%%-------------------------------------------------------------------

-behaviour(gen_server).
%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

-include("eradius_lib.hrl").
-include("dictionary_rfc2866.hrl").
-include_lib("kernel/include/inet.hrl").

%%--------------------------------------------------------------------
%% External exports
-export([start_link/0, start/0,
	 acc_on/1, acc_off/1, acc_start/1, acc_stop/1, acc_update/1,
	 set_user/2, set_nas_ip_address/1, set_nas_ip_address/2,
	 set_sockopts/2,
	 set_login_time/1, set_logout_time/1, set_session_id/2, new/0,
	 set_radacct/1, set_attr/3, set_vend_attr/2, set_vend_attr/3,
	 set_servers/2, set_timeout/2, set_login_time/2,  set_vendor_id/2,
	 set_logout_time/2, set_tc_ureq/1,
	 set_tc_itimeout/1,set_tc_stimeout/1,
	 set_tc_areset/1, set_tc_areboot/1,
	 set_tc_nasrequest/1, set_tc_nasreboot/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% The State record
-record(s, {
	  r         % #radacct{} record
	 }).

-define(SERVER,     ?MODULE).
-define(TABLENAME,  ?MODULE).

%%% ====================================================================
%%% External interface
%%% ====================================================================

%%-----------------------------------------------------------------
%% Func: auth(User, Passwd, AuthSpec)
%% Types:
%% Purpose:
%%-----------------------------------------------------------------

acc_on(Req) when is_record(Req,rad_accreq) ->
    gen_server:cast(?SERVER, {acc_on, Req}).

acc_off(Req) when is_record(Req,rad_accreq) ->
    gen_server:cast(?SERVER, {acc_off, Req}).

acc_start(Req) when is_record(Req,rad_accreq) ->
    gen_server:cast(?SERVER, {acc_start, Req}).

acc_stop(Req) when is_record(Req,rad_accreq) ->
    gen_server:cast(?SERVER, {acc_stop, Req}).

acc_update(Req) when is_record(Req,rad_accreq) ->
    gen_server:cast(?SERVER, {acc_update, Req}).

%%% Create ADT
new() -> #rad_accreq{}.

%%% Set (any) Attribute
set_attr(R, Id, Val) when is_record(R,rad_accreq),
                          is_integer(Id) ->
    StdAttrs = R#rad_accreq.std_attrs,
    R#rad_accreq{std_attrs = [{Id, Val} | StdAttrs]}.

%%% Vendor Attributes
set_vend_attr(R, VAttrs) when is_record(R,rad_accreq),
                              is_list(VAttrs) ->
    F = fun({Vid, Attrs}, NewR) ->
                set_vend_attr(NewR, Vid, Attrs);
           (_, NewR) -> NewR
        end,
    lists:foldl(F, R, VAttrs).

set_vend_attr(R, Vid, Attrs) when is_record(R,rad_accreq),
                                  is_integer(Vid),
                                  is_list(Attrs) ->
    VendAttrs = R#rad_accreq.vend_attrs,
    R#rad_accreq{vend_attrs = [{Vid, Attrs} | VendAttrs]}.

%%% Vendor Id
set_vendor_id(R, VendId) when is_record(R, rad_accreq),
                              is_integer(VendId) ->
    R#rad_accreq{vend_id = VendId}.

%%% User
set_user(R, User) when is_record(R, rad_accreq) ->
    R#rad_accreq{user = any2bin(User)}.

%%% NAS-IP
set_nas_ip_address(R) when is_record(R, rad_accreq) ->
    R#rad_accreq{nas_ip = nas_ip_address()}.

set_nas_ip_address(R, Ip) when is_record(R, rad_accreq),
                               is_tuple(Ip) ->
    R#rad_accreq{nas_ip = Ip}.

%%% Extra socket options
set_sockopts(R, SockOpts) when is_record(R, rad_accreq),
                               is_list(SockOpts) ->
    R#rad_accreq{sockopts = SockOpts}.

%%% Login / Logout
set_login_time(R) ->
    set_login_time(R, erlang:now()).

set_login_time(R, Login) when is_record(R, rad_accreq) ->
    R#rad_accreq{login_time = Login}.

set_logout_time(R) ->
     set_logout_time(R, erlang:now()).

set_logout_time(R, Logout) when is_record(R, rad_accreq) ->
    %% Login0 = Logout0 = {MSec, Sec, uSec} | is_integer()
    %% (In the second form it is erlang:now() in seconds)
    Login0 = to_now(R#rad_accreq.login_time),
    Logout0 = to_now(Logout),
    SessTime = calendar:datetime_to_gregorian_seconds(calendar:now_to_local_time(Logout0)) -
	calendar:datetime_to_gregorian_seconds(calendar:now_to_local_time(Login0)),
    R#rad_accreq{session_time = SessTime,
		 logout_time = Logout}.

%%% Terminate Cause
set_tc_ureq(R) when is_record(R, rad_accreq) ->
    R#rad_accreq{term_cause = ?Val_Acct_Terminate_Cause_User_Request}.

set_tc_itimeout(R) when is_record(R, rad_accreq) ->
    R#rad_accreq{term_cause = ?Val_Acct_Terminate_Cause_Idle_Timeout}.

set_tc_stimeout(R) when is_record(R, rad_accreq) ->
    R#rad_accreq{term_cause = ?Val_Acct_Terminate_Cause_Session_Timeout}.

set_tc_areset(R) when is_record(R, rad_accreq) ->
    R#rad_accreq{term_cause = ?Val_Acct_Terminate_Cause_Admin_Reset}.

set_tc_areboot(R) when is_record(R, rad_accreq) ->
    R#rad_accreq{term_cause = ?Val_Acct_Terminate_Cause_Admin_Reboot}.

set_tc_nasrequest(R) when is_record(R, rad_accreq) ->
    R#rad_accreq{term_cause = ?Val_Acct_Terminate_Cause_NAS_Request}.

set_tc_nasreboot(R) when is_record(R, rad_accreq) ->
    R#rad_accreq{term_cause = ?Val_Acct_Terminate_Cause_NAS_Reboot}.

%%% Session ID
set_session_id(R, Id) when is_record(R, rad_accreq) ->
    R#rad_accreq{session_id = any2bin(Id)}.

%%% Server Info
set_servers(R, Srvs) when is_record(R, rad_accreq) ->
    R#rad_accreq{servers = Srvs}.

set_timeout(R, Timeout) when is_record(R, rad_accreq),
                             is_integer(Timeout) ->
    R#rad_accreq{timeout = Timeout}.

set_radacct(Radacct) when is_record(Radacct,radacct) ->
    gen_server:call(?SERVER, {set_radacct, Radacct}).


%%====================================================================
%% External functions
%%====================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start() ->
    gen_server:start({local, ?SERVER}, ?MODULE, [], []).

%%====================================================================
%% Server functions
%%====================================================================

init([]) ->
    ets:new(?TABLENAME, [named_table, public]),
    ets:insert(?TABLENAME, {id_counter, 0}),
    {ok, #s{}}.

handle_call({set_radacct, R}, _From, State) when is_record(R, radacct) ->
    {reply, ok, State#s{r = R}}.

handle_cast({acc_on, Req}, State) ->
    punch_acc(Req, State, ?Val_Acct_Status_Type_Accounting_On),
    {noreply, State};

handle_cast({acc_off, Req}, State) ->
    punch_acc(Req, State, ?Val_Acct_Status_Type_Accounting_Off),
    {noreply, State};

handle_cast({acc_start, Req}, State) ->
    punch_acc(Req, State, ?Val_Acct_Status_Type_Start),
    {noreply, State};

handle_cast({acc_stop, Req}, State) ->
    punch_acc(Req, State, ?Val_Acct_Status_Type_Stop),
    {noreply, State};

handle_cast({acc_update, Req}, State) ->
    punch_acc(Req, State, ?Val_Acct_Status_Type_Interim_Update),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% -------------------------------------------------------------------
%%% Internal functions
%%% -------------------------------------------------------------------

punch_acc(Req, State, Stype) ->
    case get_servers(Req,State) of
	{Srvs,Timeout} ->
	    spawn(fun() -> do_punch(Srvs, Timeout,
		 Req#rad_accreq{status_type = Stype}) end);
	_ ->
	    false
    end.

%% Servers defined in the rad_accreq{} record
%% overrides the State info.
get_servers(Req,State) ->
    Def = #rad_accreq{},
    case {Req#rad_accreq.servers, Def#rad_accreq.servers} of
	{X,X} ->
	    %% Ok, Req hadn't set the servers so lets
	    %% use whatever we have in the State.
	    if is_record(State#s.r, radacct) ->
		    R = State#s.r,
		    {R#radacct.servers, R#radacct.timeout};
	       true ->
		    false
	    end;
	{Srvs,_} ->
	    {Srvs, Req#rad_accreq.timeout}
    end.

do_punch([], _Timeout, _Req) ->
    %% FIXME some nice syslog message somewhere perhaps ?
    false;
do_punch([[Ip,Port,Shared] | Rest], Timeout, Req) ->
    Id = ets:update_counter(?TABLENAME, id_counter, 1),
    PDU = eradius_lib:enc_accreq(Id, Shared, Req),
    {ok, S} = gen_udp:open(0, [binary]),
    gen_udp:send(S, Ip, Port, PDU),
    Resp = receive
	{udp, S, _IP, _Port, Packet} ->
	    eradius_lib:dec_packet(Packet)
    after Timeout ->
	    timeout
    end,
    gen_udp:close(S),
    case Resp of
	timeout ->
	    %% NB: We could implement a re-send strategy here
	    %% along the lines of what the RFC proposes.
	    do_punch(Rest, Timeout, Req);
	_ when is_record(Resp, rad_pdu) ->
	    %% Not really necessary...
	    if is_record(Resp#rad_pdu.cmd, rad_accresp) -> true;
	       true                                  -> false
	    end
    end.

to_now(Now = {MSec, Sec, USec}) when is_integer(MSec),
				     is_integer(Sec), is_integer(USec) ->
    Now;
to_now(Now) when is_integer(Now) ->
    {Now div 1000000, Now rem 1000000, 0}.

any2bin(I) when is_integer(I) -> list_to_binary(integer_to_list(I));
any2bin(L) when is_list(L)    -> list_to_binary(L);
any2bin(B) when is_binary(B)  -> B.

nas_ip_address() ->
    Host = n2h(atom_to_list(node())),
    {ok, #hostent{h_addr_list = [Ip | _]}} = inet:gethostbyname(Host),
    Ip.

n2h("@nohost") -> "localhost";
n2h([$@ | Host]) -> Host;
n2h([_H | T])    -> n2h(T);
n2h([])          -> "localhost".
