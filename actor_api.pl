% SPDX-License-Identifier: MIT

:- module(actor_api,
       [ offset/2,
         toplevel_spawn/1, toplevel_spawn/2,
         toplevel_call/2, toplevel_call/3,
         toplevel_next/1, toplevel_next/2,
         toplevel_halt/1, toplevel_halt/2,
         toplevel_stop/1, toplevel_abort/1,
         rpc/2, rpc/3,
         promise/3, promise/4, promise_cleanup/1,
         yield/2, yield/3,
         parallel/1, first_solution/2, first_solution/3,
         server_spawn/3, server_spawn/4,
         server_request/3, server_request/4,
         server_promise/3, server_promise/4,
         server_yield/2, server_yield/3, server_yield/4,
         server_upgrade/2, server_upgrade/3,
         server_halt/2, server_stop/2,
         supervisor_spawn/2, supervisor_spawn/3,
         supervisor_spawn_child/3,
         supervisor_terminate_child/3,
         supervisor_delete_child/3,
         supervisor_respawn_child/3,
         supervisor_which_children/2,
         supervisor_count_children/2,
         supervisor_halt/1, supervisor_stop/1,
         op(800,  xfx, !),
         op(200,  xfx, @),
         op(1000, xfy, if)
       ]).

/** <module> Precompiled public API imported by private actor modules */

:- use_module(toplevel_actors,
              [ offset/2,
                toplevel_spawn/1, toplevel_spawn/2,
                toplevel_call/2, toplevel_call/3,
                toplevel_next/1, toplevel_next/2,
                toplevel_halt/1, toplevel_halt/2,
                toplevel_stop/1, toplevel_abort/1
              ]).
:- use_module(rpc).
:- use_module(parallel, [parallel/1,first_solution/2,first_solution/3]).
:- use_module(server_actor).
:- use_module(supervisor_actor).
