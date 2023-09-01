%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_http_lib).

-export([ uri_encode/1
        , uri_decode/1
        , uri_parse/1
        , normalize/1
        , normalise_headers/1
        ]).

-include_lib("typerefl/include/types.hrl").

-reflect_type([uri_map/0, uri/0]).

-type uri_map() :: #{scheme := http | https | coap | coaps,
                     host := unicode:chardata() | inet:ip_address(),
                     port := non_neg_integer(),
                     path => unicode:chardata(),
                     query => unicode:chardata(),
                     fragment => unicode:chardata(),
                     userinfo => unicode:chardata()}.

-type hex_uri() :: string() | binary().
-type maybe_hex_uri() :: string() | binary(). %% A possibly hexadecimal encoded URI.
-type uri() :: string() | binary().

%% @doc Decode percent-encoded URI.
%% This is copied from http_uri.erl which has been deprecated since OTP-23
%% The recommended replacement uri_string function is not quite equivalent
%% and not backward compatible.
-spec uri_decode(maybe_hex_uri()) -> uri().
uri_decode(String) when is_list(String) ->
    do_uri_decode(String);
uri_decode(String) when is_binary(String) ->
    do_uri_decode_binary(String).

do_uri_decode([$%,Hex1,Hex2|Rest]) ->
    [hex2dec(Hex1)*16+hex2dec(Hex2)|do_uri_decode(Rest)];
do_uri_decode([First|Rest]) ->
    [First|do_uri_decode(Rest)];
do_uri_decode([]) ->
    [].

do_uri_decode_binary(<<$%, Hex:2/binary, Rest/bits>>) ->
    <<(binary_to_integer(Hex, 16)), (do_uri_decode_binary(Rest))/binary>>;
do_uri_decode_binary(<<First:1/binary, Rest/bits>>) ->
    <<First/binary, (do_uri_decode_binary(Rest))/binary>>;
do_uri_decode_binary(<<>>) ->
    <<>>.

%% @doc Encode URI.
-spec uri_encode(uri()) -> hex_uri().
uri_encode(URI) when is_list(URI) ->
    lists:append([do_uri_encode(Char) || Char <- URI]);
uri_encode(URI) when is_binary(URI) ->
    << <<(do_uri_encode_binary(Char))/binary>> || <<Char>> <= URI >>.

%% @doc Parse URI into a map as uri_string:uri_map(), but with two fields
%% normalised: (1): port number is never 'undefined', default ports are used
%% if missing. (2): scheme is always atom.
-spec uri_parse(string() | binary()) -> {ok, uri_map()} | {error, any()}.
uri_parse(URI) ->
    try
        %% ensure we return string() instead of binary() in uri_map() values.
        URI1 = maybe_add_default_scheme(unicode:characters_to_list(URI)),
        {ok, do_parse(uri_string:normalize(URI1))}
    catch
        throw : Reason ->
            {error, Reason}
    end.

do_parse({error, Reason, Which}) -> throw({Reason, Which});
do_parse(URI) ->
    normalise_parse_result(uri_string:parse(URI)).

maybe_add_default_scheme(URI) ->
    case string:split(URI, "://", leading) of
        [_Schema, _Rem] ->
            URI;
        _ ->
            "http://" ++ URI
    end.

-spec normalize(uri_map()) -> string().
normalize(#{ scheme := Scheme
           , host := Host
           } = UriMap) when is_atom(Scheme) ->
    uri_string:normalize(UriMap#{scheme => atom_to_list(Scheme),
                                 host => case inet:ntoa(Host) of
                                             {error, einval} -> Host;
                                             Address -> Address
                                         end
                                }).

%% @doc Return HTTP headers list with keys lower-cased and
%% underscores replaced with hyphens
%% NOTE: assuming the input Headers list is a proplists,
%% that is, when a key is duplicated, list header overrides tail
%% e.g. [{"Content_Type", "applicaiton/binary"}, {"content-type", "applicaiton/json"}]
%% results in: [{"content-type", "applicaiton/binary"}]
normalise_headers(Headers0) ->
    F = fun({K0, V}) ->
                K = re:replace(K0, "_", "-", [{return,list}]),
                {string:lowercase(K), V}
        end,
    Headers = lists:map(F, Headers0),
    Keys = proplists:get_keys(Headers),
    [{K, proplists:get_value(K, Headers)} || K <- Keys].

normalise_parse_result(#{host := Host, scheme := Scheme0} = Map) ->
    {Scheme, DefaultPort} = atom_scheme_and_default_port(Scheme0),
    Port = case maps:get(port, Map, undefined) of
               N when is_integer(N), N >= 0, N =< 65536 -> N;
               undefined -> DefaultPort;
               N -> erlang:throw({invalid_port, N})
           end,
    Map#{ scheme := Scheme
        , host := assert_not_empty_host(maybe_parse_ip(Host))
        , port => Port
        }.

maybe_parse_ip(Host) ->
    case inet:parse_address(Host) of
        {ok, Addr} when is_tuple(Addr) -> Addr;
        {error, einval} -> Host
    end.

%% NOTE: so far we only support http/coap schemes.
atom_scheme_and_default_port(Scheme) when is_list(Scheme) ->
    atom_scheme_and_default_port(list_to_binary(Scheme));
atom_scheme_and_default_port(<<"http">> ) -> {http,   80};
atom_scheme_and_default_port(<<"https">>) -> {https, 443};
atom_scheme_and_default_port(<<"coap">> ) -> {coap,  5683};
atom_scheme_and_default_port(<<"coaps">>) -> {coaps, 5684};
atom_scheme_and_default_port(Other) -> throw({unsupported_scheme, Other}).

do_uri_encode(Char) ->
    case reserved(Char) of
	    true ->
	        [ $% | integer_to_hexlist(Char)];
	    false ->
	        [Char]
    end.

do_uri_encode_binary(Char) ->
    case reserved(Char)  of
        true ->
            << $%, (integer_to_binary(Char, 16))/binary >>;
        false ->
            <<Char>>
    end.

reserved($;) -> true;
reserved($:) -> true;
reserved($@) -> true;
reserved($&) -> true;
reserved($=) -> true;
reserved($+) -> true;
reserved($,) -> true;
reserved($/) -> true;
reserved($?) -> true;
reserved($#) -> true;
reserved($[) -> true;
reserved($]) -> true;
reserved($<) -> true;
reserved($>) -> true;
reserved($\") -> true;
reserved(${) -> true;
reserved($}) -> true;
reserved($|) -> true;
reserved($\\) -> true;
reserved($') -> true;
reserved($^) -> true;
reserved($%) -> true;
reserved($\s) -> true;
reserved(_) -> false.

integer_to_hexlist(Int) ->
    integer_to_list(Int, 16).

hex2dec(X) when (X>=$0) andalso (X=<$9) -> X-$0;
hex2dec(X) when (X>=$A) andalso (X=<$F) -> X-$A+10;
hex2dec(X) when (X>=$a) andalso (X=<$f) -> X-$a+10.

%% -----------------------------------------------------------------------------
assert_not_empty_host(Host) when Host =:= <<>>; Host =:= "" ->
    erlang:throw(empty_host_not_allowed);
assert_not_empty_host(Host) ->
    Host.
