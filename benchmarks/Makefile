chain_csv:=chain-0.csv chain-10.csv chain-100.csv
ping_pong_csv:=ping-pong-10.csv ping-pong-100.csv
local_ping_pong_csv:=local-ping-pong-10.csv local-ping-pong-100.csv
fan_out_csv:=fan-out-10.csv fan-out-100.csv
diagonal_csv:=diagonal-10.csv diagonal-100.csv
sieve_csv:=sieve-2000.csv

csv:=$(chain_csv) $(ping_pong_csv) $(local_ping_pong_csv) $(fan_out_csv) $(diagonal_csv) $(sieve_csv)

all: $(csv)

chain-%.csv:
	../env guile ./scale-bench guile chain.scm $* '#e1e4' | tee $@

ping-pong-%.csv:
	../env guile ./scale-bench guile ping-pong.scm $* '#e1e4' | tee $@

local-ping-pong-%.csv:
	../env guile ./scale-bench guile local-ping-pong.scm $* '#e1e4' | tee $@

fan-out-%.csv:
	../env guile ./scale-bench guile fan-out.scm $* '#e1e5' | tee $@

diagonal-%.csv:
	../env guile ./scale-bench guile diagonal.scm $* '#e1e4' | tee $@

sieve-%.csv:
	../env guile ./scale-bench guile sieve.scm $* | tee $@
