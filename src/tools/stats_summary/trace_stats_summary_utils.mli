(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021-2022 Tarides <contact@tarides.com>                     *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

(** Utilities to summarise stats traces. *)

type histo = (float * int) list [@@deriving repr]
type curve = float list [@@deriving repr]

val snap_to_integer : significant_digits:int -> float -> float
(** [snap_to_integer ~significant_digits v] is [Float.round v] if [v] is close
    to [Float.round v], otherwise the result is [v]. [significant_digits]
    defines how close things are.

    Examples:

    When [significant_digits] is [4] and [v] is [42.00001], [snap_to_integer v]
    is [42.].

    When [significant_digits] is [4] and [v] is [42.001], [snap_to_integer v] is
    [v]. *)

val pp_real :
  [< `D3 | `D6 | `E | `G | `I | `M | `T ] -> Format.formatter -> float -> unit
(** [pp_real kind] is a float pretty-printer that formats given [kind]. *)

val create_pp_real :
  ?significant_digits:int -> float list -> Format.formatter -> float -> unit
(** [create_pp_real examples] is [pp_real kind] where [kind] has been
    automatically determined given [examples].

    It is highly recommended, but not mandatory, for all the numbers passed to
    [pp_real] to be included in [examples].

    When all the [examples] are integers, the display may be different. The
    examples that aren't integer, but that are very close to be a integers are
    counted as integers. [significant_digits] is used internally to snap the
    examples to integers. *)

val create_pp_seconds : float list -> Format.formatter -> float -> unit
(** [create_pp_seconds examples] is [pp_seconds], a time span pretty-printer
    that adapts to the [examples] shown to it.

    It is highly recommended, but not mandatory, for all the numbers passed to
    [pp_seconds] to be included in [examples]. *)

val pp_percent : Format.formatter -> float -> unit
(** Pretty prints a percent in a way that always takes 4 chars.

    Examples: [0.] is ["  0%"], [0.00001] is ["0.0%"], [0.003] is ["0.3%"],
    [0.15] is [" 15%"], [9.0] is [900%], [700.] is [700x], [410_000.0] is
    ["4e6x"] and [1e100] is ["++++"].

    Negative inputs are undefined. *)

(** Functional Exponential Moving Average (EMA). *)
module Exponential_moving_average : sig
  type t

  val create : ?relevance_threshold:float -> float -> t
  (** [create ?relevance_threshold m] is [ema], a functional exponential moving
      average. [1. -. m] is the fraction of what's forgotten of the past during
      each [update].

      The value represented by [ema] can be retrieved using [peek_exn ema] or
      [peek_or_nan ema].

      When [m = 0.], all the past is forgotten on each update and each forget.
      [peek_exn ema] is either the latest sample fed to an update function or
      [nan].

      When [m] approaches [1.], [peek_exn ema] tends to be the mean of all the
      samples seen in the past.

      See
      https://en.wikipedia.org/wiki/Moving_average#Exponential_moving_average

      {3 Relevance}

      The value represented by [ema] is built from the {e history} of samples
      shown through [update(_batch)]. When that history is empty, the value
      can't be calculated, and when the history is too small, or too distant
      because of calls to [forget(_batch)], the represented value is very noisy.

      [relevance_threshold] is a threshold on [ema]'s inner [void_fraction],
      below which the represented value should be considered relevant, i.e.
      [peek_or_nan ema] is not NaN.

      Before any call to [update(_batch)], the represented value is always
      irrelevant.

      After a sufficient number of updates (e.g. 1 update in general), the
      represented value gets relevant.

      After a sufficient number of forgets, the represented value gets
      irrelevant again.

      A good value for [relevance_threshold] is between [momentum] and [1.], so
      that right after a call to [update], the value is always relevant.

      {3 Commutativity}

      Adding together two curves independently built with an EMA, is equivalent
      to adding the samples beforehand, and using a single EMA.

      In a more more formal way:

      Let [a], [b] be vectors of real values of similar length.

      Let [ema(x)] be the [Exponential_moving_average.map momentum] function
      ([float list -> float list]);

      Let [*], [+] and [/] be the element-wise vector multiplication, addition
      and division.

      Then [ema(a + b)] is [ema(a) + ema(b)].

      The same is not true for multiplication and division, [ema(a * b)] is not
      [ema(a) * ema(b)], but [exp(ema(log(a * b)))] is
      [exp(ema(log(a))) * exp(ema(log(b)))] when all values in [a] and [b] are
      strictly greater than 0. *)

  val from_half_life : ?relevance_threshold:float -> float -> t
  (** [from_half_life hl] is [ema], a functional exponential moving average.
      After [hl] calls to [update], half of the past is forgotten. *)

  val from_half_life_ratio : ?relevance_threshold:float -> float -> float -> t
  (** [from_half_life_ratio hl_ratio step_count] is [ema], a functional
      exponential moving average. After [hl_ratio * step_count] calls to
      [update], half of the past is forgotten. *)

  val map : ?relevance_threshold:float -> float -> float list -> float list
  (** [map momentum vec0] is [vec1], a list of float with the same length as
      [vec0], where the values have been locally averaged.

      The first element of [vec1] is also the first element of [vec0]. *)

  val update : t -> float -> t
  (** Feed a new sample to the EMA. If the sample is not finite (i.e., NaN or
      infinite), the represented won't be either. *)

  val update_batch : t -> float -> float -> t
  (** [update_batch ema p s] is equivalent to calling [update] [s] times. Modulo
      floating point errors. *)

  val forget : t -> t
  (** [forget ema] forgets some of the past without the need for samples. The
      represented value doesn't change. *)

  val forget_batch : t -> float -> t
  (** [forget_batch ema s] is equivalent to calling [forget] [s] times. Modulo
      floating point errors.*)

  val is_relevant : t -> bool
  (** Indicates whether or not [peek_exn] can be called without raising an
      exception. *)

  val peek_exn : t -> float
  (** Read the EMA value. *)

  val peek_or_nan : t -> float
  (** Read the EMA value. *)

  val momentum : t -> float
  val hidden_state : t -> float
  val void_fraction : t -> float
end

(** This [Resample] module offers 3 ways to resample a 1d vector:

    - At the lowest level, using [should_sample].
    - Using [create_acc] / [accumulate] / [finalise].
    - At the highest level, using [resample_vector].

    Both downsampling and upsampling are possible:

    {v
    > upsampling
    vec0: |       |       |        |  (len0:4)
    vec1: |    |    |    |    |    |  (len1:6)
    > identity
    vec0: |       |       |        |  (len0:4)
    vec1: |       |       |        |  (len1:4)
    > downsampling
    vec0: |    |    |    |    |    |  (len0:6)
    vec1: |       |       |        |  (len1:4)
    v}

    The first and last point of the input and output sequences are always equal. *)
module Resample : sig
  val should_sample :
    i0:int ->
    len0:int ->
    i1:int ->
    len1:int ->
    [ `After | `Before | `Inside of float | `Out_of_bounds ]
  (** When resampling a 1d vector from [len0] to [len1], this function locates a
      destination point with index [i1] relative to the range [i0 - 1] excluded
      and [i0] included.

      When both [i0] and [i1] equal [0], the result is [`Inside 1.].

      [len0] and [len1] should be greater or equal to 2. *)

  type acc

  val create_acc :
    [ `Interpolate | `Next_neighbor ] ->
    len0:int ->
    len1:int ->
    v00:float ->
    acc
  (** Creates a resampling accumulator.

      Requires the first point of vec0. *)

  val accumulate : acc -> float -> acc
  val finalise : acc -> curve

  val resample_vector :
    [< `Interpolate | `Next_neighbor ] -> curve -> int -> curve
  (** [resample_vector mode vec0 len1] is [vec1], a curve of length [len1],
      created by resampling [vec0].

      It internally relies on the [should_sample] function. *)
end

(** Functional summary for a variable that has zero or more occurences per
    period. [accumulate] is expected to be called [in_period_count] times before
    [finalise] is.

    {3 Stats Gathered}

    - Global (non-nan) max, argmax, min, argmin and mean of the variable.
    - The very last non-nan sample encountered minus the very first non-nan
      sample encountered.
    - Global histogram made of [distribution_bin_count] bins. Option:
      [distribution_scale] to control the spreading scale of the bins, either on
      a linear or a log scale. Computed using Bentov.
    - A curve made of [out_sample_count] points. Options: [evolution_smoothing]
      to control the smoothing, either using EMA, or no smoothing at all.

    {3 Histograms}

    The histograms are all computed using https://github.com/barko/bentov.

    [Bentov] computes dynamic histograms without the need for a priori
    informations on the distributions, while maintaining a constant memory space
    and a marginal CPU footprint.

    The implementation of that library is pretty straightforward, but not
    perfect; the CPU footprint doesn't scale well with the number of bins.

    The computed histograms depend on the order of the operations, some marginal
    unsabilities are to be expected.

    [Bentov] is good at spreading the bins on the input space.

    Use [scale = `Log] when the histograms will be displayed with a log scale.
    In that case, the log10 of these values is passed to [Bentov] at
    accumulation time, but these values are exponentiated back to the right
    scale at finilisation time.

    {3 Log Scale}

    When a variable has to be displayed on a log scale, the [scale] option can
    be set to [`Log] in order for some adjustments to be made.

    In the histogram, the bins will be spread on a log scale.

    When smoothing the evolution, the EMA decay is calculated on a log scale.

    Gotcha: All the input samples should be strictly greater than 0, so that
    they don't fail their conversion to log.

    {3 Periods are Decoupled from Samples}

    When a [Variable_summary] ([vs]) is created, the number of periods has to be
    declared right away through the [in_period_count] parameter, but [vs] is
    very flexible when it comes to the number of samples shown to it on each
    period.

    The simplest use case of [vs] is when there is exactly one sample for each
    period. In that case, [accumulate acc samples] is called using a list of
    length 1. For example: when a period corresponds to a cycle of an algorithm,
    and the variable is a timestamp.

    A more advanced use case of [vs] is when there are a varying number a
    samples for each period. For example: when a period corresponds to a cycle
    of an algorithm, and the variable is the time taken by a buffer flush that
    may happen 0, 1 or more times per cycle.

    In that later case, the [evolution] curve may contain NaNs before and after
    sample points.

    Yet another use case of [vs] would be to have 1 sample for every period
    except the first one. In that case you want to pass an empty [samples] list
    the first time [accumulate vs samples] is called.

    {3 Possible Future Evolutions}

    - A period-wise histogram, similar to Grafana's heatmaps: "A heatmap is like
      a histogram, but over time where each time slice represents its own
      histogram.".

    - Variance evolution. Either without smoothing or using exponential moving
      variance (see wikipedia).

    - Global variance.

    - Quantile evolution. *)
module Variable_summary : sig
  type t = {
    max_value : float * int;
    min_value : float * int;
    mean : float;
    diff : float;
    distribution : histo;
    evolution : curve;
  }
  [@@deriving repr]

  type acc

  val create_acc :
    evolution_smoothing:[ `Ema of float * float | `None ] ->
    evolution_resampling_mode:[ `Interpolate | `Next_neighbor | `Prev_neighbor ] ->
    distribution_bin_count:int ->
    scale:[ `Linear | `Log ] ->
    in_period_count:int ->
    out_sample_count:int ->
    acc

  val accumulate : acc -> float list -> acc
  val finalise : acc -> t
end
