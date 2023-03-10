# Bin context documentation

`Lib context` is a complex piece of the Tezos codebase. It is in charge of
managing the Tezos context via objects stored on disks. It is a portion of
code we need to test. We also need to gather information about performance
from it. This document explains how to record this information from a
`Tezos node`.

While running a node, it can record two types of information:
 - __raw actions traces__: they store the actions executed by the context and
   can use them later to create summaries or replay them.
 - __stats traces__: they gather statistics about the context execution like
   time or memory space.

![workflow](https://i.imgur.com/aVFVogY.png)

## Raw actions traces (a.k.a. raw traces)

### Recording

Their purpose is to record the actions executed in the context to be replayed
later. Stats can be computed on them too. To tell the context to record actions
traces, the environment variable, `TEZOS_CONTEXT`, have to be set. The value is
the path to the directory where the data are exported. This directory **must**
exist before the run. Each process records only one trace.

* Set `TEZOS_CONTEXT` to record actions traces:
  ```shell
  $ mkdir -p /path/to/record_dir
  $ export TEZOS_CONTEXT=actions-trace-record-directory=/path/to/record_dir
  $ ./tezos-node run [...]
  ```

### Manage actions

`Manage_actions.exe` offers commands on the traces generated by the context:

* List the content of the traces:
  ```shell
  $ dune exec -- src/bin_context/manage_actions.exe list /path/to/record_dir
  ```
* Make a summary about the traces:
  ```shell
  $ dune exec -- src/bin_context/manage_actions.exe summarise \
                 /path/to/record_dir/file > out.json
  ```
* Transform a raw trace into a replayable trace:
  ```shell
  $ dune exec -- src/bin_context/manage_actions.exe to-replayable \
                 /path/to/record_dir/file > replay-trace
  ```

## Stats traces

### Recording

To record stats traces from the Tezos context, the environment variable
`TEZOS_CONTEXT` must be set. For the stats summary tool, the user can set
a `STATS_TRACE_MESSAGE` variable with a JSON format string (to display extra
information with stats summaries later).

One process records one trace.

* `STATS_TRACE_MESSAGE` format must be a flat key/value dictionnary of string:
  ```json
  { "k1" : "v1", "k2": "v2", ... }
  ```
* The directory where you are going to export the stats MUST already be created:
  ```shell
  $ mkdir -p /path/to/record_dir
  $ export TEZOS_CONTEXT=stats-trace-record-directory=/path/to/record_dir
  $ export STATS_TRACE_MESSAGE='{ "name":"my test", "revision":`git describe --always --dirty` }'
  $ ./tezos-node run [...]
  ```

It is possible to record stats traces and raw traces simultaneously. The
`TEZOS_CONTEXT` environment variable has to be set with both parameters,
separated by a comma to do so.

* Record stats traces and actions traces at the same time:
```shell
$ export TEZOS_CONTEXT=stats-trace-record-directory=/path/to/record_dir,actions-trace-record-directory=/path/to/record_dir
```

### Manage stats

You can manage the stats you have created previously and:

* Create a json summary from stats trace:
  ```shell
  $ dune exec -- src/bin_context/manage_stats.exe summarise \
                 /path/to/stats_trace > out.json
  ```

* Print a json summary (or several at the same time for comparison):
  ```shell
  $ dune exec -- src/bin_context/manage_stats.exe pp /path/to/json-0 \
                 [/path/to/json-n]* > out.txt
  ```

## Replayable actions traces (a.k.a. replay traces)

Replay.exe re executes actions as described in a replayable actions trace. It
will generate a stats trace and a summary and print it.

### Replay

```shell
 $ dune exec -- src/bin_context/replay.exe /path/to/trace artefacts_dir --startup-store-copy=/path/to/context_dir
```

The stats trace produced can be used with `manage_stats` to generate a te
xt summary (as seen before).

## Workflow example

This an example of a workflow with replay traces
```shell
 $ mkdir -p /tmp/dir
 $ export TEZOS_CONTEXT=actions-trace-record-directory=/tmp/dir
 $ ./tezos-node run [...]
 $ dune exec src/bin_context/manage_actions.exe to-replayable \
             /tmp/dir > /tmp/dir/replay-trace
 $ dune exec src/bin_context/replay.exe /tmp/dir/replay-trace /tmp/replay \
             --no-pp-summary
 $ dune exec src/bin_context/manage_stats pp \
             /tmp/replay/stats_summary.json > stats.txt
```
