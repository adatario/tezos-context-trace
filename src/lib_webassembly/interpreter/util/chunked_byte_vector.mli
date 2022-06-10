module Chunk : sig
  (** Chunk within the byte vector *)
  type t

  (** Create a chunk and copy the given bytes into it. *)
  val of_bytes : bytes -> t

  (** Size of a chunk in bytes - with 12 bits of address space the chunk is 4KiB *)
  val size : int64

  (** [num_needed len] Computes the number of chunks needed to cover [len]. *)
  val num_needed : int64 -> int64
end

module Effect : sig
  module type S = sig
    include Lazy_map.Effect.S

    val join : unit t list -> unit t
  end

  module Identity : S with type 'a t = 'a

  module Lwt : S with type 'a t = 'a Lwt.t
end

module type S = sig
  (** Effect with which chunks are created *)
  type 'a effect

  (** Chunked byte vector *)
  type t

  (** [create length] creates a chunked byte vector that has capacity for [length]
      bytes. *)
  val create : ?get_chunk:(int64 -> Chunk.t effect) -> int64 -> t

  (** [of_string str] creates a chunked byte vector from the given [str]. *)
  val of_string : string -> t effect

  (** [of_bytes bytes] creates a chunked byte vector from the given [bytes]. The
      underlying memory is effectively copied - further modifications to [bytes]
      are not reflected in the chunked byte vector. Use this over [of_string] when
      turning your [bytes] into a [string] would be potentially expensive. *)
  val of_bytes : bytes -> t effect

  (** [grow vector length_delta] increases the byte vector length by
      [length_delta]. *)
  val grow : t -> int64 -> unit

  (** [length vector] returns the length of [vector] in bytes. *)
  val length : t -> int64

  (** [load_byte vector offset] read the byte at [offset]. *)
  val load_byte : t -> int64 -> int effect

  (** [store_byte vector offset byte] set the byte at [offset] to [byte]. *)
  val store_byte : t -> int64 -> int -> unit effect

  (** [store_bytes vector offset bytes] set the bytes from [offset] to the given
      [bytes]. *)
  val store_bytes : t -> int64 -> bytes -> unit effect
end

include S with type 'a effect = 'a

module Lwt : S with type 'a effect = 'a Lwt.t