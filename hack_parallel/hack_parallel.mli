module Std : sig

  module Bucket : sig

    (* The general protocol for a next function is to return either Wait (indicating
       that workers should wait until more elements are added to the workload), or
       Job of a bucket, or Done to indicate there is no more work. *)
    type 'a bucket =
      | Job of 'a
      | Wait
      | Done

    type 'a next =
      unit -> 'a bucket

    (* Makes a bucket out of a list, without regard for number of workers or the
       size of the list.  *)
    val of_list : 'a list -> 'a list bucket

    val make : num_workers:int -> ?max_size:int -> 'a list -> 'a list next

    type 'a of_n = { work: 'a; bucket: int; total: int }

    val make_n_buckets : buckets:int -> split:(bucket:int -> 'a) ->
      'a of_n next

    (* Specialized version to split into lists only. *)
    val make_list : num_workers:int -> ?max_size:int -> 'a list -> (unit -> 'a list)


  end


  module SharedMem : sig

    (*****************************************************************************)
    (* The heap shared across all the processes.
     *
     * The Heap is not exposed directly to the user (cf shared.mli),
     * because we don't want to mix values of different types. Instead, we want
     * to use a functor.
    *)
    (*****************************************************************************)

    type config = {
      global_size      : int;
      heap_size        : int;
      dep_table_pow    : int;
      hash_table_pow   : int;
      shm_dirs         : string list;
      shm_min_avail    : int;
      log_level        : int;
    }

    type handle = private {
      h_fd: Unix.file_descr;
      h_global_size: int;
      h_heap_size: int;
    }

    exception Out_of_shared_memory
    exception Hash_table_full
    exception Dep_table_full
    exception Heap_full
    exception Sql_assertion_failure of int
    exception C_assertion_failure of string

    (*****************************************************************************)
    (* Initializes the shared memory. Must be called before forking! *)
    (*****************************************************************************)

    val init: config -> handle

    (*****************************************************************************)
    (* Connect a slave to the shared heap *)
    (*****************************************************************************)

    val connect: handle -> is_master:bool -> unit

    (*****************************************************************************)
    (* The shared memory garbage collector. It must be called every time we
     * free data (cf hh_shared.c for the underlying C implementation).
    *)
    (*****************************************************************************)

    val collect: [ `gentle | `aggressive ] -> unit

    (*****************************************************************************)
    (* Must be called after the initialization of the hack server is over.
     * (cf serverInit.ml).
    *)
    (*****************************************************************************)

    val init_done: unit -> unit

    (*****************************************************************************)
    (* Serializes the dependency table and writes it to a file *)
    (*****************************************************************************)
    val save_dep_table_sqlite: string -> string -> int

    (*****************************************************************************)
    (* Loads the dependency table by reading from a file *)
    (*****************************************************************************)
    val load_dep_table_sqlite: string -> bool -> int

    (*****************************************************************************)
    (* Cleans up the artifacts generated by SQL *)
    (*****************************************************************************)
    val cleanup_sqlite: unit -> unit

    (*****************************************************************************)
    (* The size of the dynamically allocated shared memory section *)
    (*****************************************************************************)
    val heap_size : unit -> int

    (*****************************************************************************)
    (* Stats of the statically sized hash / dep tables *)
    (*****************************************************************************)

    type table_stats = {
      nonempty_slots : int;
      used_slots : int;
      slots : int;
    }

    val dep_stats : unit -> table_stats

    val hash_stats : unit -> table_stats

    val is_heap_overflow: unit -> bool

    (*****************************************************************************)
    (* Cache invalidation. *)
    (*****************************************************************************)

    val invalidate_caches: unit -> unit

    (* Size of value in GC heap *)
    val value_size: Obj.t -> int

    (*****************************************************************************)
    (* The signature of a shared memory hashtable.
     * To create one: SharedMem.NoCache(struct type = my_type_of_value end).
     * The call to Make will create a hashtable in shared memory (visible to
     * all the workers).
     * Use NoCache/WithCache if you want caching or not.
     * If you do, bear in mind that the cache must be maintained by the caller.
     * So you will have to invalidate the caches yourself.
    *)
    (*****************************************************************************)

    module type NoCache = sig
      type key
      type t
      module KeySet : Set.S with type elt = key
      module KeyMap : MyMap.S with type key = key

      (* Safe for concurrent writes, the first writer wins, the second write
       * is dismissed.
      *)
      val add              : key -> t -> unit
      (* Safe for concurrent reads. Safe for interleaved reads and mutations,
       * provided the code runs on Intel architectures.
      *)
      val get              : key -> t option
      val get_old          : key -> t option
      val get_old_batch    : KeySet.t -> t option KeyMap.t
      val remove_old_batch : KeySet.t -> unit
      val find_unsafe      : key -> t
      val get_batch        : KeySet.t -> t option KeyMap.t
      val remove_batch     : KeySet.t -> unit
      val string_of_key    : key -> string
      (* Safe for concurrent access. *)
      val mem              : key -> bool
      val mem_old          : key -> bool
      (* This function takes the elements present in the set and keep the "old"
       * version in a separate heap. This is useful when we want to compare
       * what has changed. We will be in a situation for type-checking
       * (cf typing/typing_redecl_service.ml) where we want to compare the type
       * of a class in the previous environment vs the current type.
      *)
      val oldify_batch     : KeySet.t -> unit
      (* Reverse operation of oldify *)
      val revive_batch     : KeySet.t -> unit

      module LocalChanges : sig
        val has_local_changes : unit -> bool
        val push_stack : unit -> unit
        val pop_stack : unit -> unit
        val revert_batch : KeySet.t -> unit
        val commit_batch : KeySet.t -> unit
        val revert_all : unit -> unit
        val commit_all : unit -> unit
      end
    end

    module type WithCache = sig
      include NoCache
      val write_through : key -> t -> unit
      val get_no_cache: key -> t option
    end

    module type UserKeyType = sig
      type t
      val to_string : t -> string
      val compare : t -> t -> int
    end

    module NoCache :
      functor (UserKeyType : UserKeyType) ->
      functor (Value:Value.Type) ->
        NoCache with type t = Value.t
                 and type key = UserKeyType.t
                 and module KeySet = Set.Make (UserKeyType)
                 and module KeyMap = MyMap.Make (UserKeyType)

    module WithCache :
      functor (UserKeyType : UserKeyType) ->
      functor (Value:Value.Type) ->
        WithCache with type t = Value.t
                   and type key = UserKeyType.t
                   and module KeySet = Set.Make (UserKeyType)
                   and module KeyMap = MyMap.Make (UserKeyType)

    module type CacheType = sig
      type key
      type value

      val add: key -> value -> unit
      val get: key -> value option
      val remove: key -> unit
      val clear: unit -> unit

      val string_of_key : key -> string
      val get_size : unit -> int
    end

    module LocalCache :
      functor (UserKeyType : UserKeyType) ->
      functor (Value : Value.Type) ->
        CacheType with type key = UserKeyType.t
                   and type value = Value.t

  end


  module Worker : sig
    exception Worker_exited_abnormally of int
    (* Worker killed by Out Of Memory. *)
    exception Worker_oomed
    (** Raise this exception when sending work to a worker that is already busy.
     * We should never be doing that, and this is an assertion error. *)
    exception Worker_busy

    type send_job_failure =
      | Worker_already_exited of Unix.process_status
      | Other_send_job_failure of exn

    exception Worker_failed_to_send_job of send_job_failure

    (* The type of a worker visible to the outside world *)
    type t


    type call_wrapper = { wrap: 'x 'b. ('x -> 'b) -> 'x -> 'b }

    (*****************************************************************************)
    (* The handle is what we get back when we start a job. It's a "future"
     * (sometimes called a "promise"). The scheduler uses the handle to retrieve
     * the result of the job when the task is done (cf multiWorker.ml).
    *)
    (*****************************************************************************)
    type 'a handle

    type 'a entry
    val register_entry_point:
      restore:('a -> unit) -> 'a entry

    (* Creates a pool of workers. *)
    val make:
      (** See docs in Worker.t for call_wrapper. *)
      ?call_wrapper: call_wrapper ->
      saved_state : 'a ->
      entry       : 'a entry ->
      nbr_procs   : int ->
      gc_control  : Gc.control ->
      heap_handle : SharedMem.handle ->
      t list

    (* Call in a sub-process (CAREFUL, GLOBALS ARE COPIED) *)
    val call: t -> ('a -> 'b) -> 'a -> 'b handle

    (* Retrieves the result (once the worker is done) hangs otherwise *)
    val get_result: 'a handle -> 'a

    (* Selects among multiple handles those which are ready. *)
    type 'a selected = {
      readys: 'a handle list;
      waiters: 'a handle list;
    }
    val select: 'a handle list -> 'a selected

    (* Returns the worker which produces this handle *)
    val get_worker: 'a handle -> t

    (* Killall the workers *)
    val killall: unit -> unit
  end


  module MultiWorker : sig

    (* The protocol for a next function is to return a list of elements.
     * It will be called repeatedly until it returns an empty list.
    *)
    type 'a nextlist = 'a list Bucket.next

    val next :
      ?max_size: int ->
      Worker.t list option ->
      'a list ->
      'a list Bucket.next

    (* See definition in Bucket above *)
    type 'a bucket = 'a Bucket.bucket =
      | Job of 'a
      | Wait
      | Done

    val call :
      Worker.t list option ->
      job:('c -> 'a -> 'b) ->
      merge:('b -> 'c -> 'c) -> neutral:'c ->
      next:'a Bucket.next ->
      'c
  end


  module Daemon : sig

    (** Type-safe versions of the channels in Pervasives. *)
    type 'a in_channel
    type 'a out_channel
    type ('in_, 'out) channel_pair = 'in_ in_channel * 'out out_channel

    val to_channel :
      'a out_channel -> ?flags:Marshal.extern_flags list -> ?flush:bool ->
      'a -> unit
    val from_channel : ?timeout:Timeout.t -> 'a in_channel -> 'a
    val flush : 'a out_channel -> unit

    (* This breaks the type safety, but is necessary in order to allow select() *)
    val descr_of_in_channel : 'a in_channel -> Unix.file_descr
    val descr_of_out_channel : 'a out_channel -> Unix.file_descr
    val cast_in : 'a in_channel -> Timeout.in_channel
    val cast_out : 'a out_channel -> Pervasives.out_channel

    val close_out : 'a out_channel -> unit
    val output_string : 'a out_channel -> string -> unit

    val close_in : 'a in_channel -> unit
    val input_char : 'a in_channel -> char
    val input_value : 'a in_channel -> 'b

    (** Spawning new process *)

    (* In the absence of 'fork' on Windows, its usage must be restricted
       to Unix specifics parts.

       This module provides a mechanism to "spawn" new instance of the
       current program, but with a custom entry point (e.g. Slaves,
       DfindServer, ...). Then, alternate entry points should not depend
       on global references that may not have been (re)initialised in the
       new process.

       All required data must be passed through the typed channels.
       associated to the spawned process.

    *)

    (* Alternate entry points *)
    type ('param, 'input, 'output) entry

    (* Alternate entry points must be registered at toplevel, i.e.
       every call to `Daemon.register_entry_point` must have been
       evaluated when `Daemon.check_entry_point` is called at the
       beginning of `ServerMain.start`. *)
    val register_entry_point :
      string -> ('param -> ('input, 'output) channel_pair -> unit) ->
      ('param, 'input, 'output) entry

    (* Handler upon spawn and forked process. *)
    type ('in_, 'out) handle = {
      channels : ('in_, 'out) channel_pair;
      pid : int;
    }

    (* for unit tests *)
    val devnull : unit -> ('a, 'b) handle

    val fd_of_path : string -> Unix.file_descr
    val null_fd : unit -> Unix.file_descr

    (* Fork and run a function that communicates via the typed channels *)
    val fork :
      ?channel_mode:[ `pipe | `socket ] ->
      (* Where the daemon's output should go *)
      (Unix.file_descr * Unix.file_descr) ->
      ('param -> ('input, 'output) channel_pair -> unit) -> 'param ->
      ('output, 'input) handle

    (* Spawn a new instance of the current process, and execute the
       alternate entry point. *)
    val spawn :
      ?channel_mode:[ `pipe | `socket ] ->
      (* Where the daemon's input and output should go *)
      (Unix.file_descr * Unix.file_descr * Unix.file_descr) ->
      ('param, 'input, 'output) entry -> 'param -> ('output, 'input) handle

    (* Close the typed channels associated to a 'spawned' child. *)
    val close : ('a, 'b) handle -> unit

    (* Kill a 'spawned' child and close the associated typed channels. *)
    val kill : ('a, 'b) handle -> unit

    (* Main function, that execute a alternate entry point.
       It should be called only once. Just before the main entry point.
       This function does not return when a custom entry point is selected. *)
    val check_entry_point : unit -> unit

  end

  module String_utils : module type of String_utils

  module Socket : module type of Socket

  module Lock : module type of Lock

  module Marshal_tools : module type of Marshal_tools

end
