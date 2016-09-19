# Fibers TODO

There's lots of stuff to do.

## REPL integration

### Improve `,fibers`

```
scheme@(guile-user)> ,fibers
fiber  state
-----  -----
1      runnable
2      waiting on #<input-port ...> to become readable
3      waiting on #<channel > to become readable
4      waiting on #<channel > to become writable
5      sleeping for another 3.423s
...
```

Right now we just get "waiting", "finished", or the like.  Usefully
representing what a thread is waiting on is tricky though.  Since this
information is already present in the continuation, probably we should
not include any additional fields in the `<fiber>' data type.  If you
just give the file and the line, probably that file is in (fibers
internal) somewhere; you could traverse the stack until you leave
fibers files, but then there's the possibility that there's user-level
abstractions like RPC wrappers that the user would like to skip as
well.  A library should probably be able to hook into this
pretty-printing process.  Probably it can be done in such a way that
we can just mark certain return addresses as never interesting, and in
that case cache that value so that the user code doesn't have to be
very performant.

### `,fkill`
```
scheme@(guile-user)> ,fkill 1
```

Also `,fcancel` I guess, the difference being that killing raises and
exception and cancelling is like SIGKILL.

### `,fiber N`
```
scheme@(guile-user)> ,fiber 2
Pausing fiber 2 (was: sleeping for another 3.2s).
Entering a new prompt.  Type `,bt' for a backtrace or `,q' to continue.
scheme@(guile-user) [1]> ,bt
[backtrace for fiber]
```

How would this work, I wonder?  It's easy to get a backtrace because
we have the suspended continuation for paused fibers, but you'd want
to get the dynamic bindings too, methinks...

## Priorities

Currently fibers have no priority.  Does that matter?

## Fiber join

First, spawn-fiber needs to return the new fiber, and we need to test
that current-fiber works.  Then join-fiber on a not-finished fiber
should suspend the calling fiber, waking it up when the callee
finishes.

Do fibers each need a field for other fibers that want to join on
them?  Are there other ways?  I suspect most fibers will not be joined
and just GC'd when finished or stuck, so maybe a side table is the
right solution.

## Process death notifications

What if you are waiting on a channel but also want to get woken if the
remote process dies?  Probably in this case `select()' over two
channels would be sufficient.  At the same time, something like what
Concurrent ML does by making events first-class solves this problem
nicely.

## Documentation

The implementation is useful enough that its public interfaces should
be documented :)

## What if a fiber throws an exception?

In batch mode, probably the exception should be caught by the
scheduler, the fiber marked as finished-with-exception, and the key
and args stored as the fiber data.  If that fiber is the root fiber
for the scheduler, then perhaps the scheduler should end early?  In
any case when the scheduler ends and the root fiber threw an
exception, probably that exception should be propagated.

I guess in general uncaught exceptions should be propagated to
join-fiber callers.  If nobody is joining, then perhaps a backtrace
should be printed?  There are situations where you want a backtrace to
be printed but I don't know what they are.

Finally there are also situations when you would like to enter a
debugger.  I don't know what these situations are.  For that I guess
we can see what kind of solution to make once `,fiber` is working.

## Missing API

We need to provide API for things like:
### What is the graph?
### Who is keeping this file alive?
### What fibers are there?
### Can we detect deadlocks?
### What fibers are taking the most time?  What is the total run-time of a given fiber?
### total number of fibers ever created
### total number of fibers that ever exited

## When would we want to migrate a fiber to a different thread?

Also, how would we do it?

## Prevent scheduler from being active in multiple threads at once

A scheduler assumes that it can directly mutate some of its data
structures, meaning that it should never run on multiple threads at
once.

## `select()` or similar

We should certainly provide a `select-message` interface that returns
the first readable message, along with the channel that it came from.
For asynchronous sends that will never block, just spawning a fiber to
do the send is suffient.  This leaves out the case of wanting to wait
on the first readable or writable channel, and points to the
conclusion that we really need to look at Concurrent ML to see if we
can integrate first-class events into fibers.  See also
https://www.cs.utah.edu/plt/publications/pldi04-ff.pdf.

## Readline?  REPL over channels

Currently the REPL runs in a blocking mode that basically takes over
the thread.  That would be fine if the REPL could suspend; can we find
a way to make it suspend, integrating readline and Scheme `read' and
Scheme `write' into fibers?  Probably not in the short term, so we
will have to use kernel threads.  One REPL on a thread to interact
with the user, and fibers run in other threads.  We need to package
this up so that a user can have a nice experience.

## Update HTTP lib to use suspendable operations

Change the HTTP library in Guile to always use suspendable operations
instead of `display' et al.

## Blog post!

"lightweight concurrency in guile with fibers" or something.
