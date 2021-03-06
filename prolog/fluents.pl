:- module(fluent, [
    fluent_create/3,
    fluent_get/3,
    fluent_destroy/1]).

/** <module> Access all solutions of a goal without backtracking

This module lets you turn any goal into a Fluent
([Tarau 2002](http://www.cse.unt.edu/~tarau/research/LeanProlog/RefactoringPrologWithFluents.pdf)). A Fluent, as
defined here, is a stateful object that encapsulates a Prolog goal as it is
interpreted. The solutions generated by the encapsulated goal on backtracking
can be accessed by the caller _without_ backtracking.

This is useful e.g. for iterating over solutions while building up a data
structure (which would be destroyed by backtracking) or to solve several
goals in parallel while keeping the solutions in sync (e.g. “zipping”), while
avoiding error-prone and/or inefficient tricks like non-backtrackable
assignment or materializing lists of solutions.

This implementation achieves backtracking-free access by delegating the
backtracking to a separate Prolog thread that sends copies of solutions back to
the calling thread via message queues, on demand. This technique was described by Samer Abdallah [on the SWI-Prolog mailing list](https://groups.google.com/d/msg/swi-prolog/jSrSL3fl3bY/fNxpE6ZcBQAJ). The implementation was also inspired by
[Michael Hendricks’ =|lazy_findall|= implementation](https://github.com/mndrix/list_util/blob/master/prolog/lazy_findall.pl).

Example usage:

==
?- fluent_create(X, member(X, [1, 2, 3]), Fluent).
Fluent = fluent(2, <message_queue>(0x94613b8)).

?- fluent_get($Fluent, X, Exit). % Exit = nondet if further solutions may exist
X = 1,
Exit = nondet.

?- fluent_get($Fluent, X, Exit).
X = 2,
Exit = nondet.

?- fluent_get($Fluent, X, Exit).
X = 3,
Exit = det.

?- fluent_get($Fluent, X, Exit). % Fails after solutions are exhausted
false.

?- fluent_get($Fluent, X, Exit). % Just keeps failing
false.

?- fluent_destroy($Fluent). % Don't forget to release resources
true.

?- fluent_create(X, X is 3 / 0, Fluent).
Fluent = fluent(3, <message_queue>(0x9465640)).

?- fluent_get($Fluent, X, Exit). % Exceptions are re-raised by fluent_get/3
ERROR: //2: Arithmetic: evaluation error: `zero_divisor'
?- fluent_destroy($Fluent).
true.

?- fluent_create(X, (member(X, [1, 2]), write(X), nl), Fluent).
Fluent = fluent(4, <message_queue>(0x9415880)).

?- fluent_get($Fluent, X, Exit). % No side effects before fluent_get/3 call
1
X = 1,
Exit = nondet.

?- fluent_get($Fluent, X, Exit).
2
X = 2,
Exit = det.

?- fluent_destroy($Fluent).
true.
==

@license MIT
@author Kilian Evang
*/

%:- debug(fluent).

:- meta_predicate fluent_create(?, 0, -).

%%	fluent_create(+Template, :Goal, -Fluent) is det.
%
%	Creates a fluent that will call Goal and send instantiations of
%	Template as solutions. Goal is not yet called at this point.
%	Fluent is a term that should be treated as an opaque reference, it may
%	change in future versions.
%
fluent_create(Template, Goal, fluent(Thread, ResponseQueue)) :-
  message_queue_create(ResponseQueue),
  thread_create(fluent_work(Template, Goal, ResponseQueue), Thread, []).

%%	fluent_get(+Fluent, -Solution, -Exit) is semidet.
%
%	Attempts to get the next solution from the fluent.
%
%	If the goal in the fluent exits, Solution is unified with a copy of the
%	corresponding instantiation of the template given when the fluent was
%	created, and Exit is unified with =det= or =nondet= depending on
%	whether the goal exited without or with open choicepoints.
%
%	If the goal in the fluent raises an exception while trying to get the
%	next solution, =|fluent_get/3|=	re-raises it.
%
%	After all solutions are exhausted, all subsequent calls to
%	=|fluent_get/3|= on this fluent fail (until it is destroyed).
%
fluent_get(fluent(Thread, ResponseQueue), Template, Exit) :-
  thread_send_message(Thread, next),
  thread_get_message(ResponseQueue, Message),
  (  Message = exception(Exception)
  -> raise_exception(Exception)
  ;  Message = solution(Template, Exit)
  ).  % fail if Message is =end=

%%	fluent_destroy(+Fluent) is det.
%
%	Destroys the fluent and frees its resources. This should always be done
%	when the fluent is no longer needed, regardless of whether it has
%	further solutions or not. Subsequent calls to =|fluent_get/3|= will
%	raise an exception.
%
fluent_destroy(fluent(Thread, ResponseQueue)) :-
  thread_send_message(Thread, done),
  thread_join(Thread, _),
  message_queue_destroy(ResponseQueue).

fluent_work(Template, Goal, ResponseQueue) :-
  % Decide whether to try to get the first solution:
  thread_get_message(Message0),
  (  Message0 == next
  -> ( % Get and send solutions (or exceptions) as we backtrack:
       catch(
           ( call_cleanup(Goal, D = true),
             ( D == true -> Exit = det ; Exit = nondet ),
             thread_send_message(ResponseQueue, solution(Template, Exit))
           ), Exception,
           ( thread_send_message(ResponseQueue, exception(Exception))
           ) ), % when this fails, we go into the second fluent_work/3 clause
       % Decide whether to try to get another solution:
       thread_get_message(Message),
       (  Message == next
       -> fail % backtrack into Goal
       ;  ! % fluent destroyed, succeed deterministically
       )
     )
  ;  !). % fluent destroyed before 1st solution, succeed deterministically
fluent_work(_, _, ResponseQueue) :-
  repeat, % allow client to keep requesting solutions,
  thread_send_message(ResponseQueue, end), % always answer end 
  thread_get_message(Message),
  (  Message == next
  -> fail % backtrack to repeat
  ;  ! % make fluent_work/3 goal succeed deterministically
  ).
