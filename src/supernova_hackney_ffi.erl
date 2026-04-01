-module(supernova_hackney_ffi).
-export([configure/0]).

configure() ->
    application:set_env(hackney, recv_timeout, 120000),
    application:set_env(hackney, connect_timeout, 30000),
    ok.
