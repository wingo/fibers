# Fibers

Fibers is a facility that provides Erlang-like concurrency for Guile
Scheme.


## A pasteable introduction to using Fibers

```scheme
;; Paste this into your guile interpreter!

(use-modules (fibers) (fibers channels) (ice-9 match))

(define (server in out)
  (let lp ()
    (match (pk 'server-received (get-message in))
      ('ping! (put-message out 'pong!))
      ('sup   (put-message out 'not-much-u))
      (msg    (put-message out (cons 'wat msg))))
    (lp)))

(define (client in out)
  (for-each (lambda (msg)
              (put-message out msg)
              (pk 'client-received (get-message in)))
            '(ping! sup)))

(run-fibers
 (lambda ()
   (let ((c2s (make-channel))
         (s2c (make-channel)))
     (spawn-fiber (lambda () (server c2s s2c)))
     (client s2c c2s))))
```

If you paste the above at into a Guile REPL, it prints out:

```scheme
;;; (server-received ping!)

;;; (client-received pong!)

;;; (server-received sup)

;;; (client-received not-much-u)
```


## Contact info

Mailing List: `guile-user@gnu.org`

Homepage: https://github.com/wingo/fibers

Download: https://wingolog.org/pub/fibers/


## Build dependencies

Guile 2.1.4 or newer (http://www.gnu.org/software/guile/).


## Installation quickstart

Install from a release tarball using the standard autotools
incantation:

```
./configure --prefix=/opt/guile && make && make install
```

Build from Git is the same, except run `autoreconf -vif` first.

You can run without installing, just run `./env guile`.


## Copying Fibers

Distribution of Fibers is under the LGPLv3+. See the `COPYING` and
`COPYING.LESSER` files for more information.


## Copying this file

Copyright (C) 2016 Free Software Foundation, Inc.

Copying and distribution of this file, with or without modification, are
permitted in any medium without royalty provided the copyright notice
and this notice are preserved.
