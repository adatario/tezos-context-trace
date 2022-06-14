(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
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

module String_map = Map.Make (String)
module String_set = Set.Make (String)

let ( // ) = Filename.concat

let has_prefix ~prefix string =
  let prefix_len = String.length prefix in
  String.length string >= prefix_len && String.sub string 0 prefix_len = prefix

let string_for_all p s =
  let n = String.length s in
  let rec loop i =
    if i = n then true else if p (String.get s i) then loop (succ i) else false
  in
  loop 0

let has_error = ref false

let info fmt = Format.eprintf fmt

let error fmt =
  Format.ksprintf
    (fun s ->
      has_error := true ;
      Format.eprintf "Error: %s" s)
    fmt

(*****************************************************************************)
(*                                  DUNE                                     *)
(*****************************************************************************)

module Ne_list = struct
  (* Non-empty lists. *)
  type 'a t = 'a * 'a list

  let to_list (head, tail) = head :: tail
end

module Dune = struct
  type kind = Library | Executable

  type mode = Byte | Native | JS

  let string_of_mode = function
    | Byte -> "byte"
    | Native -> "native"
    | JS -> "js"

  type s_expr =
    | E
    | S of string
    | G of s_expr
    | H of s_expr
    | V of s_expr
    | []
    | ( :: ) of s_expr * s_expr

  type language = C

  type foreign_stubs = {
    language : language;
    flags : string list;
    names : string list;
  }

  (* Test whether an s-expression is empty. *)
  let rec is_empty = function
    | E -> true
    | S _ -> false
    | G s | H s | V s -> is_empty s
    | [] -> true
    | head :: tail -> is_empty head && is_empty tail

  (* Pretty-print an atom of an s-expression. *)
  let pp_atom fmt atom =
    let rec need_quotes i =
      if i >= String.length atom then false
      else
        (* https://dune.readthedocs.io/en/stable/lexical-conventions.html#atoms
           (\012 is formfeed) *)
        match atom.[i] with
        | ' ' | '\t' | '\n' | '\012' | '(' | ')' | '"' | ';' -> true
        | _ -> need_quotes (i + 1)
    in
    if atom = "" || need_quotes 0 then
      (* https://dune.readthedocs.io/en/stable/lexical-conventions.html#strings
         It appears that %S should work in most cases, except that:
         - the dune documentation does not explicitely say that it supports escaping
           double quotes;
         - the dune documentation says to escape %{ otherwise it is understood as a variable.
         I tested and escaping double quotes actually works (with dune 2.9.0 at least).
         For variables, we actually want to be able to use variables in our atoms,
         so not escaping them is actually useful. In conclusion, %S looks fine. *)
      Format.fprintf fmt "%S" atom
    else Format.pp_print_string fmt atom

  (* Pretty-print an s-expression. *)
  let rec pp_s_expr fmt s_expr =
    (* If [need_space] is [true], a separator is printed before the first atom, if any.
       This is only used inside lists (i.e. the :: constructor) . *)
    let rec pp_s_expr_items need_space fmt = function
      | E -> ()
      | S atom -> pp_atom fmt atom
      | G _ | H _ | V _ ->
          (* See below: [invalid_arg] prevents this from happening. *)
          assert false
      | [] -> ()
      | E :: tail -> pp_s_expr_items need_space fmt tail
      | G s_expr :: tail ->
          if is_empty s_expr then pp_s_expr_items need_space fmt tail
          else (
            if need_space then Format.pp_print_space fmt () ;
            Format.fprintf fmt "@[<hov>%a@]" (pp_s_expr_items false) s_expr ;
            pp_s_expr_items true fmt tail)
      | H s_expr :: tail ->
          if is_empty s_expr then pp_s_expr_items need_space fmt tail
          else (
            if need_space then Format.pp_print_space fmt () ;
            Format.fprintf fmt "@[<h>%a@]" (pp_s_expr_items false) s_expr ;
            pp_s_expr_items true fmt tail)
      | V s_expr :: tail ->
          if is_empty s_expr then pp_s_expr_items need_space fmt tail
          else (
            if need_space then Format.pp_print_space fmt () ;
            Format.fprintf fmt "@[<v>%a@]" (pp_s_expr_items false) s_expr ;
            pp_s_expr_items true fmt tail)
      | head :: tail ->
          if need_space then Format.pp_print_space fmt () ;
          pp_s_expr fmt head ;
          pp_s_expr_items true fmt tail
    in
    match s_expr with
    | E -> ()
    | S atom -> pp_atom fmt atom
    | G _ | H _ | V _ ->
        invalid_arg
          "Dune.pp_sexpr: grouped s-expressions must be inside s-expressions"
    | [] | _ :: _ ->
        Format.fprintf fmt "(@[<hv>%a@])" (pp_s_expr_items false) s_expr

  let pp fmt dune =
    let rec pp is_first_item fmt = function
      | E -> ()
      | S _ -> invalid_arg "Dune.pp: argument must be a list, not an atom"
      | G _ | H _ | V _ ->
          invalid_arg
            "Dune.pp: grouped s-expressions must be inside s-expressions"
      | [] -> ()
      | E :: tail -> pp is_first_item fmt tail
      | head :: tail ->
          if not is_first_item then Format.fprintf fmt "@.@." ;
          Format.fprintf fmt "%a%a" pp_s_expr head (pp false) tail
    in
    pp true fmt dune

  let of_list list =
    List.fold_left (fun acc item -> item :: acc) [] (List.rev list)

  (* Convert a list of atoms (i.e. strings) to an [s_expr]. *)
  let of_atom_list atoms =
    List.fold_left (fun acc item -> S item :: acc) [] (List.rev atoms)

  (* Helper to define s-expressions where parts are optional.

     Basically the same as [Option.bind] except that [None] becomes [E]. *)
  let opt o f = match o with None -> E | Some x -> f x

  let executable_or_library kind ?(public_names = Stdlib.List.[]) ?package
      ?(instrumentation = Stdlib.List.[]) ?(libraries = []) ?flags
      ?library_flags ?link_flags ?(inline_tests = false)
      ?(preprocess = Stdlib.List.[]) ?(preprocessor_deps = Stdlib.List.[])
      ?(wrapped = true) ?modules ?modules_without_implementation ?modes
      ?foreign_stubs ?c_library_flags ?(private_modules = Stdlib.List.[])
      ?js_of_ocaml (names : string list) =
    [
      V
        [
          S
            (match (kind, names) with
            | Library, [_] -> "library"
            | Library, _ -> "libraries"
            | Executable, [_] -> "executable"
            | Executable, _ -> "executables");
          (match names with
          | [name] -> [S "name"; S name]
          | _ -> S "names" :: of_atom_list names);
          (match public_names with
          | [] -> E
          | [name] -> [S "public_name"; S name]
          | _ :: _ -> S "public_names" :: of_atom_list public_names);
          opt package (fun x -> [S "package"; S x]);
          (match instrumentation with
          | [] -> E
          | _ ->
              G
                (of_list
                @@ List.map (fun x -> [S "instrumentation"; x]) instrumentation
                ));
          ( opt modes @@ fun x ->
            S "modes"
            :: of_list (List.map (function mode -> S (string_of_mode mode)) x)
          );
          (match libraries with
          | [] -> E
          | _ -> [V (S "libraries" :: libraries)]);
          (if inline_tests then
           let modes : mode list =
             match (modes, js_of_ocaml) with
             | None, None ->
                 (* Make the default dune behavior explicit *)
                 [Native]
             | None, Some _ -> [Native; JS]
             | Some modes, _ ->
                 (* always preserve mode if specified *)
                 modes
           in
           [
             S "inline_tests";
             [S "flags"; S "-verbose"];
             S "modes"
             :: of_list (List.map (fun mode -> S (string_of_mode mode)) modes);
           ]
          else E);
          (match preprocess with
          | [] -> E
          | _ :: _ -> S "preprocess" :: of_list preprocess);
          (match preprocessor_deps with
          | [] -> E
          | _ :: _ -> S "preprocessor_deps" :: of_list preprocessor_deps);
          (match js_of_ocaml with
          | None -> E
          | Some flags -> S "js_of_ocaml" :: flags);
          opt library_flags (fun x -> [S "library_flags"; x]);
          opt link_flags (fun x -> [S "link_flags"; x]);
          opt flags (fun x -> [S "flags"; x]);
          (if not wrapped then [S "wrapped"; S "false"] else E);
          opt modules (fun x -> S "modules" :: x);
          opt modules_without_implementation (fun x ->
              S "modules_without_implementation" :: x);
          (match private_modules with
          | [] -> E
          | _ -> S "private_modules" :: of_atom_list private_modules);
          ( opt foreign_stubs @@ fun x ->
            [
              S "foreign_stubs";
              [S "language"; (match x.language with C -> S "c")];
              (match x.flags with
              | [] -> E
              | _ -> [S "flags"; of_atom_list x.flags]);
              S "names" :: of_atom_list x.names;
            ] );
          (opt c_library_flags @@ fun x -> [S "c_library_flags"; of_atom_list x]);
        ];
    ]

  let alias ?(deps = Stdlib.List.[]) name =
    [
      S "alias";
      [S "name"; S name];
      (match deps with [] -> E | _ -> S "deps" :: of_atom_list deps);
    ]

  let alias_rule ?(deps = Stdlib.List.[]) ?(alias_deps = Stdlib.List.[])
      ?deps_dune ?action ?locks ?package name =
    let deps =
      match (deps, alias_deps, deps_dune) with
      | _ :: _, _, Some _ | _, _ :: _, Some _ ->
          invalid_arg
            "Dune.alias_rule: cannot specify both ~deps_dune and ~deps or \
             ~alias_deps"
      | [], [], Some deps -> deps
      | _, _, None ->
          List.map (fun x -> S x) deps
          @ List.map (fun x -> [S "alias"; S x]) alias_deps
          |> of_list
    in
    [
      S "rule";
      [S "alias"; S name];
      (opt package @@ fun x -> [S "package"; S x]);
      (match deps with [] -> E | _ -> S "deps" :: deps);
      (opt locks @@ fun locks -> [S "locks"; S locks]);
      [
        S "action";
        (match action with None -> [S "progn"] | Some action -> action);
      ];
    ]

  let run command args = [S "run"; S command; G (of_atom_list args)]

  let run_exe exe_name args = run ("%{exe:" ^ exe_name ^ ".exe}") args

  let runtest_js ?(alias = "runtest_js") ?package ~dep_files name =
    alias_rule
      alias
      ?package
      ~deps:dep_files
      ~action:[S "run"; S "node"; S ("%{dep:./" ^ name ^ ".bc.js}")]

  let file name = [S "file"; S name]

  let glob_files expr = [S "glob_files"; S expr]

  let runtest ?(alias = "runtest") ?package ~dep_files ~dep_globs name =
    let deps_dune =
      let files = List.map (fun s -> S s) dep_files in
      let globs = List.map glob_files dep_globs in
      match files @ globs with [] -> None | deps -> Some (of_list deps)
    in
    alias_rule
      alias
      ?package
      ?deps_dune
      ~action:[S "run"; S ("%{dep:./" ^ name ^ ".exe}")]

  let setenv name value followup = [G [S "setenv"; S name; S value]; followup]

  let chdir_workspace_root followup =
    [G [S "chdir"; S "%{workspace_root}"]; followup]

  let backend name = [S "backend"; S name]

  let ocamllex name = [S "ocamllex"; S name]

  let ocamlyacc name = [S "ocamlyacc"; S name]

  let pps ?(args = Stdlib.List.[]) name = S "pps" :: S name :: of_atom_list args

  let include_ name = [S "include"; S name]

  let targets_rule ?deps targets ~action =
    [
      S "rule";
      [S "targets"; G (of_atom_list targets)];
      (match deps with None -> E | Some deps -> [S "deps"; G (of_list deps)]);
      [S "action"; action];
    ]

  let install ?package files ~section =
    [
      S "install";
      (match package with
      | None -> E
      | Some package -> [S "package"; S package]);
      [S "section"; S section];
      [S "files"; G (of_list files)];
    ]

  let as_ target alias = [S target; S "as"; S alias]
end

(*****************************************************************************)
(*                                VERSIONS                                   *)
(*****************************************************************************)

module Version = struct
  type t = string

  type atom = V of t | Version

  (* Note: opam does not actually support [False], which makes sense since
     why would one want to have a dependency which cannot be installed.
     We support [False] in order to be able to negate any version constraint. *)
  type constraints =
    | True
    | False
    | Exactly of atom
    | Different_from of atom
    | At_least of atom
    | More_than of atom
    | At_most of atom
    | Less_than of atom
    | Not of constraints
    | And of constraints * constraints
    | Or of constraints * constraints

  let exactly x = Exactly (V x)

  let different_from x = Different_from (V x)

  let at_least x = At_least (V x)

  let more_than x = More_than (V x)

  let at_most x = At_most (V x)

  let less_than x = Less_than (V x)

  let not_ = function
    | True -> False
    | False -> True
    | Exactly x -> Different_from x
    | Different_from x -> Exactly x
    | At_least x -> Less_than x
    | More_than x -> At_most x
    | At_most x -> More_than x
    | Less_than x -> At_least x
    | Not x -> x
    | (And _ | Or _) as x ->
        (* We could distribute but it could lead to an exponential explosion. *)
        Not x

  let ( && ) a b =
    match (a, b) with
    | True, x | x, True -> x
    | False, _ | _, False -> False
    | _ -> And (a, b)

  let and_list = List.fold_left ( && ) True

  let ( || ) a b =
    match (a, b) with
    | True, _ | _, True -> True
    | False, x | x, False -> x
    | _ -> Or (a, b)

  let or_list = List.fold_left ( || ) False
end

module Npm = struct
  type t = {package : string; version : Version.constraints}

  let make package version = {package; version}

  let node_preload t =
    match String.index_opt t.package '/' with
    | None -> t.package
    | Some i -> String.sub t.package (i + 1) (String.length t.package - i - 1)
end

(*****************************************************************************)
(*                                  OPAM                                     *)
(*****************************************************************************)

type with_test = Always | Never | Only_on_64_arch

let show_with_test = function
  | Always -> "Always"
  | Never -> "Never"
  | Only_on_64_arch -> "Only_on_64_arch"

module Opam = struct
  type dependency = {
    package : string;
    version : Version.constraints;
    with_test : with_test;
    optional : bool;
  }

  type command_item = A of string | S of string

  type build_instruction = {command : command_item list; with_test : with_test}

  type url = {url : string; sha256 : string option; sha512 : string option}

  type t = {
    maintainer : string;
    authors : string list;
    homepage : string;
    bug_reports : string;
    dev_repo : string;
    licenses : string list;
    depends : dependency list;
    conflicts : dependency list;
    build : build_instruction list;
    synopsis : string;
    url : url option;
    description : string option;
    x_opam_monorepo_opam_provided : string list;
  }

  let pp fmt
      {
        maintainer;
        authors;
        homepage;
        bug_reports;
        dev_repo;
        licenses;
        depends;
        conflicts;
        build;
        synopsis;
        url;
        description;
        x_opam_monorepo_opam_provided;
      } =
    let depopts, depends = List.partition (fun dep -> dep.optional) depends in
    let depopts, conflicts =
      (* Opam documentation says this about [depopts]:
         "If you require specific versions, add a [conflicts] field with the ones
         that won't work."
         One could assume that this is because version constraints need to existe
         whether the optional dependencies are selected or not?
         In any case the following piece of code converts version constraints
         on optional dependencies into conflicts. *)
      let optional_dep_conflicts =
        let negate_dependency_constraint dependency =
          match dependency.version with
          | True ->
              (* No conflict to introduce. *)
              None
          | version -> Some {dependency with version = Version.not_ version}
        in
        List.filter_map negate_dependency_constraint depopts
      in
      let depopts =
        let remove_constraint dependency = {dependency with version = True} in
        List.map remove_constraint depopts
      in
      let conflicts = conflicts @ optional_dep_conflicts in
      (depopts, conflicts)
    in
    let pp_line x =
      Format.kfprintf (fun fmt -> Format.pp_print_newline fmt ()) fmt x
    in
    let pp_string fmt string =
      (* https://opam.ocaml.org/doc/Manual.html#General-syntax
         <string> ::= ( (") { <char> }* (") ) | ( (""") { <char> }* (""") )
         (and there is no definition for <char> so let's assume it is "any byte").
         In other words: if there is no double quote, we can just put the whole
         string in double quotes. Otherwise, we need to use three double quotes.
         If the string itself contains three consecutive double quotes, it seems
         that we are doomed. *)
      let len = String.length string in
      let rec check_quotes default i =
        if i >= len then default
        else if string.[i] <> '"' then
          (* Continue looking for quotes. *)
          check_quotes default (i + 1)
        else if i + 2 >= len then
          (* Found a quote, and there is no space for two more quotes. *)
          `use_triple_quotes
        else if string.[i + 1] = '"' then
          (* Found two consecutive quotes. *)
          if string.[i + 2] = '"' then `doomed
          else
            (* Not three consecutive quotes: continue looking for quotes.
               If we don't find anything, the default is now to use three double quotes. *)
            check_quotes `use_triple_quotes (i + 3)
        else
          (* Not three consecutive quotes: continue looking for quotes. *)
          check_quotes `use_triple_quotes (i + 2)
      in
      match check_quotes `use_regular_quotes 0 with
      | `use_regular_quotes -> Format.fprintf fmt "\"%s\"" string
      | `use_triple_quotes -> Format.fprintf fmt "\"\"\"%s\"\"\"" string
      | `doomed ->
          invalid_arg
            "Cannot use strings with three consecutive double-quotes in opam \
             strings."
    in
    let pp_list ?(v = false) ?(prefix = "") pp_item fmt = function
      | [] -> Format.fprintf fmt "%s[]" prefix
      | list ->
          let pp_sep_out =
            if v then Format.pp_force_newline else Format.pp_print_cut
          in
          let pp_sep_in =
            if v then Format.pp_force_newline else Format.pp_print_space
          in
          Format.fprintf
            fmt
            "@[@[<hv 2>%s[%a%a@]%a]@]"
            prefix
            pp_sep_out
            ()
            (Format.pp_print_list ~pp_sep:pp_sep_in pp_item)
            list
            pp_sep_out
            ()
    in
    let pp_version_atom fmt = function
      | Version.V x -> pp_string fmt x
      | Version -> Format.pp_print_string fmt "version"
    in
    let rec pp_version_constraint ~in_and fmt = function
      | Version.True ->
          invalid_arg "pp_version_constraint cannot be called with True"
      | False -> invalid_arg "pp_version_constraint cannot be called with False"
      | Exactly version -> Format.fprintf fmt "= %a" pp_version_atom version
      | Different_from version ->
          Format.fprintf fmt "!= %a" pp_version_atom version
      | At_least version -> Format.fprintf fmt ">= %a" pp_version_atom version
      | More_than version -> Format.fprintf fmt "> %a" pp_version_atom version
      | At_most version -> Format.fprintf fmt "<= %a" pp_version_atom version
      | Less_than version -> Format.fprintf fmt "< %a" pp_version_atom version
      | Not atom ->
          Format.fprintf fmt "! (%a)" (pp_version_constraint ~in_and:false) atom
      | And (a, b) ->
          Format.fprintf
            fmt
            "%a & %a"
            (pp_version_constraint ~in_and:true)
            a
            (pp_version_constraint ~in_and:true)
            b
      | Or (a, b) ->
          Format.fprintf
            fmt
            "%s%a & %a%s"
            (if in_and then "(" else "")
            (pp_version_constraint ~in_and:false)
            a
            (pp_version_constraint ~in_and:false)
            b
            (if in_and then ")" else "")
    in
    let condition_of_with_test = function
      | Always -> ["with-test"]
      | Never -> []
      | Only_on_64_arch ->
          ["with-test"; "arch != \"arm32\""; "arch != \"x86_32\""]
    in
    let pp_condition fmt = function
      | [] -> ()
      | ["with-test"] -> Format.pp_print_string fmt " {with-test}"
      | items ->
          Format.fprintf
            fmt
            " { %a }"
            (Format.pp_print_list
               ~pp_sep:(fun fmt () -> Format.pp_print_string fmt " & ")
               Format.pp_print_string)
            items
    in
    let pp_dependency fmt {package; version; with_test; _} =
      let condition =
        let with_test = condition_of_with_test with_test in
        let version =
          match version with
          | True -> []
          | _ ->
              [
                Format.asprintf
                  "%a"
                  (pp_version_constraint ~in_and:false)
                  version;
              ]
        in
        List.concat [with_test; version]
      in
      Format.fprintf fmt "@[%a%a@]" pp_string package pp_condition condition
    in
    let pp_command_item fmt = function
      | A atom -> Format.pp_print_string fmt atom
      | S string -> pp_string fmt string
    in
    let pp_build_instruction fmt {command; with_test} =
      Format.fprintf
        fmt
        "%a%a"
        (pp_list pp_command_item)
        command
        pp_condition
        (condition_of_with_test with_test)
    in
    let pp_url {url; sha256; sha512} =
      pp_line "url {" ;
      pp_line "  src: \"%s\"" url ;
      if sha256 <> None || sha512 <> None then (
        pp_line "  checksum: [" ;
        Option.iter (fun sha256 -> pp_line "    \"sha256=%s\"" sha256) sha256 ;
        Option.iter (fun sha512 -> pp_line "    \"sha512=%s\"" sha512) sha512 ;
        pp_line "  ]") ;
      pp_line "}"
    in
    pp_line "opam-version: \"2.0\"" ;
    pp_line "maintainer: %a" pp_string maintainer ;
    pp_line "%a" (pp_list ~prefix:"authors: " pp_string) authors ;
    pp_line "homepage: %a" pp_string homepage ;
    pp_line "bug-reports: %a" pp_string bug_reports ;
    pp_line "dev-repo: %a" pp_string dev_repo ;
    (match licenses with
    | [license] -> pp_line "license: %a" pp_string license
    | _ -> pp_line "license: %a" (pp_list pp_string) licenses) ;
    pp_line "%a" (pp_list ~v:true ~prefix:"depends: " pp_dependency) depends ;
    if depopts <> [] then
      pp_line "%a" (pp_list ~v:true ~prefix:"depopts: " pp_dependency) depopts ;
    if x_opam_monorepo_opam_provided <> [] then
      pp_line
        "%a"
        (pp_list ~v:true ~prefix:"x-opam-monorepo-opam-provided: " pp_string)
        x_opam_monorepo_opam_provided ;
    if conflicts <> [] then
      pp_line
        "%a"
        (pp_list ~v:true ~prefix:"conflicts: " pp_dependency)
        conflicts ;
    pp_line "%a" (pp_list ~prefix:"build: " pp_build_instruction) build ;
    pp_line "synopsis: %a" pp_string synopsis ;
    Option.iter pp_url url ;
    Option.iter (pp_line "description: %a" pp_string) description
end

module Flags = struct
  type t = {standard : bool; rest : Dune.s_expr list}

  type maker =
    ?nopervasives:bool ->
    ?nostdlib:bool ->
    ?opaque:bool ->
    ?warnings:string ->
    ?warn_error:string ->
    unit ->
    t

  let if_true b name = if b then Dune.S name else Dune.E

  let if_some o name = match o with None -> Dune.E | Some x -> H [S name; S x]

  let make ~standard ?(nopervasives = false) ?(nostdlib = false)
      ?(opaque = false) ?warnings ?warn_error () =
    {
      standard;
      rest =
        [
          if_some warnings "-w";
          if_some warn_error "-warn-error";
          if_true nostdlib "-nostdlib";
          if_true nopervasives "-nopervasives";
          if_true opaque "-opaque";
        ];
    }

  let standard = make ~standard:true

  let no_standard = make ~standard:false

  let include_ f = {standard = false; rest = Dune.[S ":include"; S f]}
end

module Env : sig
  (* See manifest.mli for documentation *)

  type t

  type profile = Profile of string | Any

  val empty : t

  val to_s_expr : t -> Dune.s_expr

  val add : profile -> key:string -> Dune.s_expr -> t -> t
end = struct
  type entry = string * Dune.s_expr

  type profile = Profile of string | Any

  type t = (profile * entry) list

  let empty = []

  let add profile ~key payload env =
    (match profile with
    | Profile "_" ->
        invalid_arg "Env.add: [Provide \"_\"] is not allowed. Use [Any]."
    | Profile _ | Any -> ()) ;
    (profile, (key, payload)) :: env

  let s_expr_of_entry (name, payload) = Dune.[S name; payload]

  let to_s_expr (t : t) =
    let any, names =
      List.partition_map
        (function
          | Any, entry -> Left entry | Profile name, entry -> Right (name, entry))
        t
    in
    let names =
      List.fold_left
        (fun names (n, entry) ->
          String_map.update
            n
            (function
              | None -> Some [entry] | Some prev -> Some (entry :: prev))
            names)
        String_map.empty
        names
    in
    let names =
      match any with
      | [] -> names
      | _ -> String_map.add "_" any (String_map.map (fun x -> any @ x) names)
    in
    String_map.iter
      (fun name entries ->
        let entry_names = List.map fst entries in
        if
          List.length (List.sort_uniq compare entry_names)
          <> List.length entry_names
        then invalid_arg ("Env.to_s_expr: duplicated entry in env " ^ name))
      names ;
    if String_map.is_empty names then Dune.E
    else
      let compare_key ((a : string), _) (b, _) =
        match (a, b) with
        | "_", "_" -> 0
        | "_", _ -> 1
        | _, "_" -> -1
        | _ -> compare a b
      in
      let l : Dune.s_expr list =
        List.map
          (fun (name, entries) ->
            Dune.(
              S name
              :: of_list
                   (List.map s_expr_of_entry (List.sort compare_key entries))))
          (List.sort compare_key (String_map.bindings names))
      in
      Dune.(S "env" :: of_list l)
end

(*****************************************************************************)
(*                                 TARGETS                                   *)
(*****************************************************************************)

module Target = struct
  let invalid_argf x = Printf.ksprintf invalid_arg x

  type external_ = {
    name : string;
    main_module : string option;
    opam : string option;
    version : Version.constraints;
    js_compatible : bool;
    npm_deps : Npm.t list;
  }

  type vendored = {
    name : string;
    main_module : string option;
    js_compatible : bool;
    npm_deps : Npm.t list;
    released_on_opam : bool;
  }

  type opam_only = {
    name : string;
    version : Version.constraints;
    can_vendor : bool;
  }

  type modules =
    | All
    | Modules of string list
    | All_modules_except of string list

  (* [internal_name] is the name for [name] stanzas in [dune] while [public_name] is the
     name for [public_name] stanzas in [dune] and the name in [.opam] files. *)
  type full_name = {internal_name : string; public_name : string}

  type kind =
    | Public_library of full_name
    | Private_library of string
    | Public_executable of full_name Ne_list.t
    | Private_executable of string Ne_list.t
    | Test_executable of {
        names : string Ne_list.t;
        runtest_alias : string option;
      }

  type preprocessor_dep = File of string

  type internal = {
    bisect_ppx : bool;
    time_measurement_ppx : bool;
    c_library_flags : string list option;
    conflicts : t list;
    deps : t list;
    dune : Dune.s_expr;
    flags : Flags.t option;
    foreign_stubs : Dune.foreign_stubs option;
    inline_tests : bool;
    js_compatible : bool;
    js_of_ocaml : Dune.s_expr option;
    documentation : Dune.s_expr option;
    kind : kind;
    linkall : bool;
    modes : Dune.mode list option;
    modules : modules;
    modules_without_implementation : string list;
    ocaml : Version.constraints option;
    opam : string option;
    opam_with_test : with_test;
    opens : string list;
    path : string;
    preprocess : preprocessor list;
    preprocessor_deps : preprocessor_dep list;
    private_modules : string list;
    opam_only_deps : t list;
    release : bool;
    static : bool;
    static_cclibs : string list;
    synopsis : string option;
    description : string option;
    wrapped : bool;
    npm_deps : Npm.t list;
    cram : bool;
    license : string option;
    extra_authors : string list;
  }

  and preprocessor = PPS of t * string list

  and inline_tests = Inline_tests_backend of t

  and select = {
    package : t;
    source_if_present : string;
    source_if_absent : string;
    target : string;
  }

  and t =
    | Internal of internal
    | Vendored of vendored
    | External of external_
    | Opam_only of opam_only
    | Optional of t
    | Select of select
    | Open of t * string

  let rec get_internal = function
    | Internal i -> Some i
    | Optional t -> get_internal t
    | Open (t, _) -> get_internal t
    | Select {package; _} -> get_internal package
    | Vendored _ -> None
    | External _ -> None
    | Opam_only _ -> None

  let pps ?(args = []) = function
    | None -> invalid_arg "Manifest.Target.pps cannot be given no_target"
    | Some target -> PPS (target, args)

  let inline_tests_backend = function
    | None ->
        invalid_arg
          "Manifest.Target.inline_tests_backend cannot be given no_target"
    | Some target -> Inline_tests_backend target

  let convert_to_identifier = String.map @@ function '-' | '.' -> '_' | c -> c

  (* List of all targets, in reverse order of registration. *)
  let registered = ref []

  (* List of targets sorted by path,
     so that we can create dune files with multiple targets. *)
  let by_path = ref String_map.empty

  (* List of targets sorted by opam package name,
     so that we can create opam files with multiple targets. *)
  let by_opam = ref String_map.empty

  let register_internal ({path; opam; _} as internal) =
    let old = String_map.find_opt path !by_path |> Option.value ~default:[] in
    by_path := String_map.add path (internal :: old) !by_path ;
    Option.iter
      (fun opam ->
        let old =
          String_map.find_opt opam !by_opam |> Option.value ~default:[]
        in
        by_opam := String_map.add opam (internal :: old) !by_opam)
      opam ;
    registered := internal :: !registered ;
    Some (Internal internal)

  (* Note: this function is redefined below for the version with optional targets. *)
  let rec name_for_errors = function
    | Vendored {name; _} | External {name; _} | Opam_only {name; _} -> name
    | Optional target | Select {package = target; _} | Open (target, _) ->
        name_for_errors target
    | Internal {kind; _} -> (
        match kind with
        | Public_library {public_name = name; _}
        | Private_library name
        | Public_executable ({public_name = name; _}, _)
        | Private_executable (name, _)
        | Test_executable {names = name, _; _} ->
            name)

  let rec names_for_dune = function
    | Vendored {name; _} | External {name; _} | Opam_only {name; _} -> (name, [])
    | Optional target | Select {package = target; _} | Open (target, _) ->
        names_for_dune target
    | Internal {kind; _} -> (
        match kind with
        | Public_library {public_name; _} -> (public_name, [])
        | Private_library internal_name -> (internal_name, [])
        | Public_executable (head, tail) ->
            (head.public_name, List.map (fun x -> x.public_name) tail)
        | Private_executable names | Test_executable {names; _} -> names)

  let rec library_name_for_dune = function
    | Vendored {name; _} | External {name; _} | Opam_only {name; _} -> Ok name
    | Optional target | Select {package = target; _} | Open (target, _) ->
        library_name_for_dune target
    | Internal {kind; _} -> (
        match kind with
        | Public_library {public_name; _} -> Ok public_name
        | Private_library internal_name -> Ok internal_name
        | Public_executable ({public_name = name; _}, _)
        | Private_executable (name, _)
        | Test_executable {names = name, _; _} ->
            Error name)

  let iter_internal_by_path f =
    String_map.iter (fun path internals -> f path (List.rev internals)) !by_path

  let iter_internal_by_opam f =
    String_map.iter (fun opam internals -> f opam (List.rev internals)) !by_opam

  type 'a maker =
    ?all_modules_except:string list ->
    ?bisect_ppx:bool ->
    ?c_library_flags:string list ->
    ?conflicts:t option list ->
    ?deps:t option list ->
    ?dune:Dune.s_expr ->
    ?flags:Flags.t ->
    ?foreign_stubs:Dune.foreign_stubs ->
    ?inline_tests:inline_tests ->
    ?js_compatible:bool ->
    ?js_of_ocaml:Dune.s_expr ->
    ?documentation:Dune.s_expr ->
    ?linkall:bool ->
    ?modes:Dune.mode list ->
    ?modules:string list ->
    ?modules_without_implementation:string list ->
    ?npm_deps:Npm.t list ->
    ?ocaml:Version.constraints ->
    ?opam:string ->
    ?opam_with_test:with_test ->
    ?opens:string list ->
    ?preprocess:preprocessor list ->
    ?preprocessor_deps:preprocessor_dep list ->
    ?private_modules:string list ->
    ?opam_only_deps:t option list ->
    ?release:bool ->
    ?static:bool ->
    ?static_cclibs:string list ->
    ?synopsis:string ->
    ?description:string ->
    ?time_measurement_ppx:bool ->
    ?wrapped:bool ->
    ?cram:bool ->
    ?license:string ->
    ?extra_authors:string list ->
    path:string ->
    'a ->
    t option

  let node_preload deps : string list =
    let collect deps =
      let rec loop (seen, acc) dep =
        match library_name_for_dune dep with
        | Error _ -> (seen, acc)
        | Ok name -> (
            if String_set.mem name seen then (seen, acc)
            else
              match dep with
              | Internal {deps; npm_deps; _} ->
                  let acc = List.map Npm.node_preload npm_deps @ acc in
                  let seen = String_set.add name seen in
                  loops (seen, acc) deps
              | External {npm_deps; _} ->
                  let seen = String_set.add name seen in
                  (seen, List.map Npm.node_preload npm_deps @ acc)
              | Vendored {npm_deps; _} ->
                  let seen = String_set.add name seen in
                  (seen, List.map Npm.node_preload npm_deps @ acc)
              | Select {package; _} -> loop (seen, acc) package
              | Opam_only _ -> (seen, acc)
              | Optional t -> loop (seen, acc) t
              | Open (t, _) -> loop (seen, acc) t)
      and loops (seen, acc) deps =
        List.fold_left
          (fun (seen, acc) x -> loop (seen, acc) x)
          (seen, acc)
          deps
      in
      loops (String_set.empty, []) deps
    in
    snd (collect deps)

  let internal make_kind ?all_modules_except ?bisect_ppx ?c_library_flags
      ?(conflicts = []) ?(dep_files = []) ?(dep_globs = []) ?(deps = [])
      ?(dune = Dune.[]) ?flags ?foreign_stubs ?inline_tests ?js_compatible
      ?js_of_ocaml ?documentation ?(linkall = false) ?modes ?modules
      ?(modules_without_implementation = []) ?(npm_deps = []) ?ocaml ?opam
      ?(opam_with_test = Always) ?(opens = []) ?(preprocess = [])
      ?(preprocessor_deps = []) ?(private_modules = []) ?(opam_only_deps = [])
      ?release ?static ?static_cclibs ?synopsis ?description
      ?(time_measurement_ppx = false) ?(wrapped = true) ?(cram = false) ?license
      ?(extra_authors = []) ~path names =
    let conflicts = List.filter_map Fun.id conflicts in
    let deps = List.filter_map Fun.id deps in
    let opam_only_deps = List.filter_map Fun.id opam_only_deps in
    let opens =
      let rec get_opens acc = function
        | Internal _ | Vendored _ | External _ | Opam_only _ -> acc
        | Optional target | Select {package = target; _} -> get_opens acc target
        | Open (target, module_name) -> get_opens (module_name :: acc) target
      in
      List.flatten (List.map (get_opens []) deps) @ opens
    in
    let js_compatible, js_of_ocaml =
      match (js_compatible, js_of_ocaml) with
      | Some false, Some _ ->
          invalid_arg
            "Target.internal: cannot specify both `~js_compatible:false` and \
             `~js_of_ocaml`"
      | Some true, Some jsoo -> (true, Some jsoo)
      | Some true, None -> (true, Some Dune.[])
      | None, Some jsoo -> (true, Some jsoo)
      | Some false, None | None, None -> (false, None)
    in
    let kind = make_kind names in
    let preprocess, inline_tests =
      match inline_tests with
      | None -> (preprocess, false)
      | Some (Inline_tests_backend target) -> (
          match kind with
          | Public_library _ | Private_library _ ->
              (PPS (target, []) :: preprocess, true)
          | Public_executable _ | Private_executable _ | Test_executable _ ->
              invalid_arg
                "Target.internal: cannot specify `inline_tests` for \
                 executables and tests")
    in
    let opam =
      match opam with
      | Some "" -> (
          match kind with
          | Test_executable {names = name, _; runtest_alias = Some _; _} ->
              invalid_argf
                "for targets which provide test executables such as %S, you \
                 must specify a non-empty ~opam or have it not run by default \
                 with ~runtest:false"
                name
          | Public_library {public_name; _} ->
              invalid_argf
                "public_library %s cannot have ~opam set to empty string (\"\")"
                public_name
          | Public_executable ({public_name; _}, _) ->
              invalid_argf
                "for targets which provide public executables such as %S, you \
                 cannot have ~opam set to empty string (\"\")"
                public_name
          | Test_executable {runtest_alias = None; _}
          | Private_library _ | Private_executable _ ->
              None)
      | Some opam as x ->
          if
            string_for_all
              (function
                | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
                | _ -> false)
              opam
          then (
            (match kind with
            | Public_library {public_name; _} -> (
                (* We allow an opam package on public_library even if
                   it's not necessary.  We just need to make sure
                   [package] agrees with [public_name] *)
                match String.split_on_char '.' public_name with
                | [] -> assert false
                | first :: _ ->
                    if first <> opam then
                      error
                        "Mismatch between public_name %S and opam package %S\n"
                        public_name
                        opam)
            | _ -> ()) ;
            x)
          else
            invalid_argf
              "%s is not a valid opam package name: should be of the form \
               [A-Za-z0-9_-]+"
              opam
      | None -> (
          match kind with
          | Public_library {public_name; _} -> (
              match String.split_on_char '.' public_name with
              | [] -> assert false
              | first :: _ -> Some first)
          | Public_executable ({public_name; _}, []) -> Some public_name
          | Public_executable ({public_name; _}, _ :: _) ->
              invalid_argf
                "for targets which provide more than one public executables \
                 such as %S, you must specify ~opam (set it to \"\" for no \
                 opam file)"
                public_name
          | Private_library name ->
              invalid_argf
                "for targets which provide private libraries such as %S, you \
                 must specify ~opam (set it to \"\" for no opam file)"
                name
          | Private_executable (name, _) ->
              invalid_argf
                "for targets which provide private executables such as %S, you \
                 must specify ~opam (set it to \"\" for no opam file)"
                name
          | Test_executable {names = name, _; _} ->
              invalid_argf
                "for targets which provide test executables such as %S, you \
                 must specify ~opam (set it to \"\" for no opam file)"
                name)
    in
    let () =
      match kind with
      | Public_library {public_name; _} -> (
          match
            List.filter_map
              (function
                | Internal {kind = Private_library name; opam = private_pkg; _}
                  when opam <> private_pkg ->
                    Some name
                | _ -> None)
              deps
          with
          | [] -> ()
          | privates ->
              error
                "The public library %s depend on private libraries not part of \
                 the same package: %s"
                public_name
                (String.concat ", " privates))
      | _ -> ()
    in
    let release =
      match release with
      | Some release -> release
      | None -> ( match kind with Public_executable _ -> true | _ -> false)
    in
    let static =
      match static with
      | Some static -> static
      | None -> (
          match static_cclibs with
          | Some _ -> true
          | None -> (
              match kind with Public_executable _ -> true | _ -> false))
    in
    let static_cclibs = Option.value static_cclibs ~default:[] in
    let modules =
      match (modules, all_modules_except) with
      | None, None -> All
      | Some modules, None -> Modules modules
      | None, Some all_modules_except -> All_modules_except all_modules_except
      | Some _, Some _ ->
          invalid_arg
            "Target.internal: cannot specify both ?modules and \
             ?all_modules_except"
    in
    let not_a_test =
      match kind with
      | Public_library _ | Private_library _ | Public_executable _
      | Private_executable _ ->
          true
      | Test_executable _ -> false
    in
    let bisect_ppx = Option.value bisect_ppx ~default:not_a_test in
    let runtest_rules =
      let run_js = js_compatible in
      let run_native =
        match modes with
        | None | Some [] -> true
        | Some modes -> List.mem Dune.Native modes
      in
      match (kind, opam, dep_files) with
      | Test_executable {names; runtest_alias = Some alias}, package, _ ->
          let runtest_js_rules =
            if run_js then
              List.map
                (fun name ->
                  Dune.runtest_js
                    ~alias:(alias ^ "_js")
                    ~dep_files
                    ?package
                    name)
                (Ne_list.to_list names)
            else []
          in
          let runtest_rules =
            if run_native then
              List.map
                (fun name ->
                  Dune.runtest ~alias ~dep_files ~dep_globs ?package name)
                (Ne_list.to_list names)
            else []
          in
          runtest_rules @ runtest_js_rules
      | Test_executable {names = name, _; runtest_alias = None}, _, _ :: _ ->
          invalid_argf
            "for targets which provide test executables such as %S, ~dep_files \
             is only meaningful for the runtest alias. It cannot be used with \
             no alias, i.e. ~alias:\"\"."
            name
      | _, _, _ :: _ -> assert false
      | _ -> []
    in
    let dune =
      List.fold_right (fun x dune -> Dune.(x :: dune)) runtest_rules dune
    in
    register_internal
      {
        bisect_ppx;
        time_measurement_ppx;
        c_library_flags;
        conflicts;
        deps;
        dune;
        flags;
        foreign_stubs;
        inline_tests;
        js_compatible;
        js_of_ocaml;
        documentation;
        kind;
        linkall;
        modes;
        modules;
        modules_without_implementation;
        ocaml;
        opam;
        opam_with_test;
        opens;
        path;
        preprocess;
        preprocessor_deps;
        private_modules;
        opam_only_deps;
        release;
        static;
        static_cclibs;
        synopsis;
        description;
        npm_deps;
        wrapped;
        cram;
        license;
        extra_authors;
      }

  let public_lib ?internal_name =
    internal ?dep_files:None ?dep_globs:None @@ fun public_name ->
    let internal_name =
      Option.value internal_name ~default:(convert_to_identifier public_name)
    in
    Public_library {internal_name; public_name}

  let private_lib =
    internal ?dep_files:None ?dep_globs:None @@ fun name -> Private_library name

  let public_exe ?internal_name =
    internal ?dep_files:None ?dep_globs:None @@ fun public_name ->
    let internal_name =
      Option.value internal_name ~default:(convert_to_identifier public_name)
    in
    Public_executable ({internal_name; public_name}, [])

  let public_exes ?internal_names =
    internal ?dep_files:None ?dep_globs:None @@ fun public_names ->
    let names =
      match internal_names with
      | None ->
          List.map
            (fun public_name ->
              {internal_name = convert_to_identifier public_name; public_name})
            public_names
      | Some internal_names -> (
          try
            List.map2
              (fun internal_name public_name -> {internal_name; public_name})
              internal_names
              public_names
          with Invalid_argument _ ->
            invalid_argf
              "Target.public_exes: you must specify exactly one internal name \
               per public name")
    in
    match names with
    | [] -> invalid_argf "Target.public_exes: at least one name must be given"
    | head :: tail -> Public_executable (head, tail)

  let private_exe =
    internal ?dep_files:None ?dep_globs:None @@ fun internal_name ->
    Private_executable (internal_name, [])

  let private_exes =
    internal ?dep_files:None ?dep_globs:None @@ fun internal_names ->
    match internal_names with
    | [] -> invalid_argf "Target.private_exes: at least one name must be given"
    | head :: tail -> Private_executable (head, tail)

  let test ?(alias = "runtest") ?dep_files ?dep_globs =
    let runtest_alias = if alias = "" then None else Some alias in
    internal ?dep_files ?dep_globs @@ fun test_name ->
    Test_executable {names = (test_name, []); runtest_alias}

  let tests ?(alias = "runtest") ?dep_files ?dep_globs =
    let runtest_alias = if alias = "" then None else Some alias in
    internal ?dep_files ?dep_globs @@ fun test_names ->
    match test_names with
    | [] -> invalid_arg "Target.tests: at least one name must be given"
    | head :: tail -> Test_executable {names = (head, tail); runtest_alias}

  let vendored_lib ?(released_on_opam = true) ?main_module
      ?(js_compatible = false) ?(npm_deps = []) name =
    Some
      (Vendored {name; main_module; js_compatible; npm_deps; released_on_opam})

  let external_lib ?main_module ?opam ?(js_compatible = false) ?(npm_deps = [])
      name version =
    let opam =
      match opam with None -> Some name | Some "" -> None | Some _ as x -> x
    in
    Some (External {name; main_module; opam; version; js_compatible; npm_deps})

  let rec external_sublib ?main_module ?(js_compatible = false) ?(npm_deps = [])
      parent name =
    match parent with
    | External {opam; version; _} ->
        External {name; main_module; opam; version; js_compatible; npm_deps}
    | Opam_only _ ->
        invalid_arg
          "Target.external_sublib: parent must be a non-opam-only external lib"
    | Internal _ | Vendored _ ->
        invalid_arg "Target.external_sublib: parent must be an external lib"
    | Optional _ ->
        invalid_arg
          "Target.external_sublib: Optional should be used in dependency \
           lists, not when registering"
    | Select _ ->
        invalid_arg
          "Target.external_sublib: Select should be used in dependency lists, \
           not when registering"
    | Open (target, module_name) ->
        Open (external_sublib target name, module_name)

  let external_sublib ?main_module ?js_compatible ?npm_deps parent name =
    match parent with
    | None -> invalid_arg "external_sublib cannot be called with no_target"
    | Some parent ->
        Some (external_sublib ?main_module ?js_compatible ?npm_deps parent name)

  let opam_only ?(can_vendor = true) name version =
    Some (Opam_only {name; version; can_vendor})

  let optional = function None -> None | Some target -> Some (Optional target)

  let open_ ?m target =
    let rec main_module_name = function
      | Internal {kind; _} -> (
          match kind with
          | Public_library {internal_name; _} | Private_library internal_name ->
              String.capitalize_ascii internal_name
          | Public_executable _ | Private_executable _ | Test_executable _ ->
              invalid_argf
                "Manifest.open_: cannot be used on executable and test targets \
                 (such as %s)"
                (name_for_errors target))
      | Optional target | Select {package = target; _} | Open (target, _) ->
          main_module_name target
      | Vendored {main_module = Some main_module; _}
      | External {main_module = Some main_module; _} ->
          String.capitalize_ascii main_module
      | Vendored {main_module = None; _} ->
          invalid_argf
            "Manifest.open_: cannot be used on vendored targets with no \
             specified main module (such as %s)"
            (name_for_errors target)
      | External {main_module = None; _} ->
          invalid_argf
            "Manifest.open_: cannot be used on external targets with no \
             specified main module (such as %s)"
            (name_for_errors target)
      | Opam_only _ ->
          invalid_argf
            "Manifest.open_: cannot be used on opam-only targets (such as %s)"
            (name_for_errors target)
    in
    let main_module_name = main_module_name target in
    let module_name =
      match m with
      | None -> main_module_name
      | Some m -> main_module_name ^ "." ^ String.capitalize_ascii m
    in
    Open (target, module_name)

  let open_ ?m = function None -> None | Some target -> Some (open_ ?m target)

  let open_if ?m condition target =
    if condition then open_ ?m target else target

  let select ~package ~source_if_present ~source_if_absent ~target =
    match package with
    | None -> None
    | Some package ->
        Some (Select {package; source_if_present; source_if_absent; target})

  let all_internal_deps internal =
    List.map (fun (PPS (target, _)) -> target) internal.preprocess
    @ internal.deps @ internal.opam_only_deps
end

type target = Target.t option

let no_target = None

let if_some = function None -> None | Some x -> x

let if_ condition target = if condition then target else None

type release = {version : string; url : Opam.url}

type tezt_target = {
  opam : string;
  deps : target list;
  dep_globs : string list;
  modules : string list;
}

let tezt_targets_by_path : tezt_target String_map.t ref = ref String_map.empty

let tezt ~opam ~path ?(deps = []) ?(dep_globs = []) modules =
  if String_map.mem path !tezt_targets_by_path then
    invalid_arg
      ("cannot call Manifest.tezt twice for the same directory: " ^ path) ;
  let tezt_target = {opam; deps; dep_globs; modules} in
  tezt_targets_by_path := String_map.add path tezt_target !tezt_targets_by_path

let register_tezt_targets ~make_tezt_exe =
  let tezt_test_libs = ref [] in
  let register_path path {opam; deps; dep_globs; modules} =
    let path_with_underscores =
      String.map (function '-' | '/' -> '_' | c -> c) path
    in
    let lib =
      (* [linkall] is used to ensure that the test executable is linked with
         [module_name] and [tezt]. *)
      Target.private_lib
        (path_with_underscores ^ "_tezt_lib")
        ~path
        ~opam:""
        ~deps
        ~modules
        ~linkall:true
    in
    tezt_test_libs := lib :: !tezt_test_libs ;
    let exe_name = "main" in
    let _exe =
      (* Alias is "runtezt" and not "runtest" to make sure that the test is
         not run in the CI twice (once with [dune @src/.../runtest] and once
         with [dune exec tezt/tests/main.exe]). *)
      Target.test
        exe_name
        ~alias:"runtezt"
        ~path
        ~opam
        ~deps:[lib]
        ~dep_globs
        ~modules:[exe_name]
        ~dune:
          Dune.
            [
              targets_rule
                [exe_name ^ ".ml"]
                ~action:
                  [
                    S "with-stdout-to";
                    S "%{targets}";
                    [S "echo"; S "let () = Tezt.Test.run ()"];
                  ];
            ]
    in
    ()
  in
  String_map.iter register_path !tezt_targets_by_path ;
  make_tezt_exe !tezt_test_libs

(*****************************************************************************)
(*                                GENERATOR                                  *)
(*****************************************************************************)

let checks_done = ref false

(* Gather the list of generated files so that we can find out whether
   there are other files that we should have generated. *)
let generated_files = ref String_set.empty

let rec create_parent path =
  let parent = Filename.dirname path in
  if String.length parent < String.length path then (
    create_parent parent ;
    if not (Sys.file_exists parent) then Sys.mkdir parent 0o755)

let write_raw filename f =
  let real_filename =
    if Filename.is_relative filename then Filename.parent_dir_name // filename
    else filename
  in
  create_parent real_filename ;
  let outch = open_out real_filename in
  let fmt = Format.formatter_of_out_channel outch in
  match f fmt with
  | exception exn ->
      Format.pp_print_flush fmt () ;
      close_out outch ;
      raise exn
  | x ->
      Format.pp_print_flush fmt () ;
      close_out outch ;
      x

(* Write a file relatively to the root directory of the repository. *)
let write filename f =
  if !checks_done then
    failwith ("trying to generate " ^ filename ^ " after [check] was run") ;
  if String_set.mem filename !generated_files then
    failwith
      (filename ^ " is generated twice; did you declare the same library twice?") ;
  generated_files := String_set.add filename !generated_files ;
  write_raw filename f

let generate_dune ~dune_file_has_static_profile (internal : Target.internal) =
  let libraries, empty_files_to_create =
    let empty_files_to_create = ref [] in
    let rec get_library (dep : Target.t) =
      let name =
        match Target.library_name_for_dune dep with
        | Ok name -> name
        | Error name ->
            invalid_arg
              ("unsupported: in "
              ^ Target.name_for_errors (Internal internal)
              ^ ": dependency on a target that is not a library (" ^ name ^ ")"
              )
      in
      match dep with
      | Opam_only _ -> Dune.E
      | Internal _ | External _ | Vendored _ -> Dune.S name
      | Optional _ ->
          (* [Optional] dependencies abuse the alternative dependency mechanism of dune.
             The semantic of [(select a from (b -> c) (-> d))] is: if libraries
             [b] are present, [cp c a] and link [b] else [cp d a]. Here, we don't
             care about the cp part as we are not using the file obtained at
             all. So, we give them names only meant to not clash with anything
             and copy always the same (generated itself) empty file "void_for_linking". *)
          let fix_name = String.map @@ function '.' -> '-' | c -> c in
          let void_name = "void_for_linking-" ^ fix_name name in
          let empty_name = void_name ^ ".empty" in
          empty_files_to_create := empty_name :: !empty_files_to_create ;
          Dune.
            [
              H [S "select"; S void_name; S "from"];
              [H [S name; S "->"; S empty_name]];
              [H [S "->"; S empty_name]];
            ]
      | Select {package = _; source_if_present; source_if_absent; target} ->
          Dune.
            [
              G [S "select"; S target; S "from"];
              [G [S name; S "->"; S source_if_present]];
              [G [S "->"; S source_if_absent]];
            ]
      | Open (target, _) -> get_library target
    in
    let libraries = List.map get_library internal.deps |> Dune.of_list in
    (libraries, List.rev !empty_files_to_create)
  in
  let is_lib =
    match internal.kind with
    | Public_library _ | Private_library _ -> true
    | Public_executable _ | Private_executable _ | Test_executable _ -> false
  in
  let library_flags =
    if internal.linkall && is_lib then Some Dune.[S ":standard"; S "-linkall"]
    else None
  in
  let link_flags =
    if internal.linkall && not is_lib then
      Some Dune.[S ":standard"; S "-linkall"]
    else None
  in
  let open_flags : Dune.s_expr list =
    internal.opens |> List.map (fun m -> Dune.(H [S "-open"; S m]))
  in
  let minus_flags : Dune.s_expr =
    if dune_file_has_static_profile && not internal.static then
      (* Disable static compilation for this particular target
         (the static profile is global for the dune file).
         This must be at the end of the flag list. *)
      Dune.(H [S "\\"; S "-ccopt"; S "-static"])
    else Dune.E
  in
  let flags =
    match (internal.flags, minus_flags, open_flags) with
    | None, Dune.E, [] -> None
    | flags, _, _ ->
        let flags =
          match flags with None -> Flags.standard () | Some flags -> flags
        in
        let flags =
          match (flags.standard, minus_flags) with
          | false, _ -> flags.rest
          | true, E -> Dune.[S ":standard"] :: flags.rest
          | true, minus_flags -> Dune.[S ":standard"; minus_flags] :: flags.rest
        in
        Some Dune.(V [V (of_list flags); V (of_list open_flags)])
  in

  let preprocess =
    let make_pp (PPS (target, args) : Target.preprocessor) =
      match Target.names_for_dune target with
      | name, [] -> Dune.pps ~args name
      | hd, (_ :: _ as tl) ->
          invalid_arg
            ("preprocessor target has multiple names, don't know which one to \
              choose: "
            ^ String.concat ", " (hd :: tl))
    in
    List.map make_pp internal.preprocess
  in
  let preprocessor_deps =
    let make_pp_dep (Target.File filename) = Dune.file filename in
    List.map make_pp_dep internal.preprocessor_deps
  in
  let modules =
    match internal.modules with
    | All -> None
    | Modules modules -> Some (Dune.of_atom_list modules)
    | All_modules_except modules ->
        Some Dune.[S ":standard" :: S "\\" :: Dune.of_atom_list modules]
  in
  let modules_without_implementation =
    match internal.modules_without_implementation with
    | [] -> None
    | _ :: _ as modules -> Some (Dune.of_atom_list modules)
  in
  let create_empty_files =
    match empty_files_to_create with
    | [] -> Dune.E
    | _ :: _ ->
        let make_write empty_file =
          (* We use H instead of G because we *really* need those to be on
             a single line until we update link_protocol.sh. *)
          Dune.[H [S "write-file"; S empty_file; S ""]]
        in
        let writes =
          List.map make_write empty_files_to_create |> Dune.of_list
        in
        Dune.[S "rule"; [S "action"; S "progn" :: writes]]
  in
  let package =
    match (internal.kind, internal.opam) with
    | Public_executable _, None ->
        (* Prevented by [Target.internal]. *)
        assert false
    | Public_executable _, (Some _ as opam) -> opam
    | Private_executable _, None -> None
    | Private_executable _, Some _opam ->
        (* private executable can't have a package stanza, but we still want the manifest to know about the package *)
        None
    | Public_library _, None ->
        (* Prevented by [Target.internal]. *)
        assert false
    | Public_library _, Some _ -> None
    | Private_library _, opam ->
        (* Private library can have an optional package.
           - No package means: global to the entire repo
           - A package means: private for the [opam] package only *)
        opam
    | Test_executable _, Some _ ->
        (* private executable can't have a package stanza, but we still want the manifest to know about the package *)
        None
    | Test_executable {runtest_alias = None; _}, None -> None
    | Test_executable {runtest_alias = Some _; _}, None ->
        (* Prevented by [Target.internal]. *)
        assert false
  in

  let instrumentation =
    let bisect_ppx =
      if internal.bisect_ppx then Some (Dune.backend "bisect_ppx") else None
    in
    let time_measurement_ppx =
      if internal.time_measurement_ppx then
        Some (Dune.backend "tezos-time-measurement")
      else None
    in
    List.filter_map (fun x -> x) [bisect_ppx; time_measurement_ppx]
  in
  let (kind : Dune.kind), internal_names, public_names =
    let get_internal_name {Target.internal_name; _} = internal_name in
    let get_public_name {Target.public_name; _} = public_name in
    match internal.kind with
    | Public_library name ->
        (Library, [get_internal_name name], [get_public_name name])
    | Private_library name -> (Library, [name], [])
    | Public_executable (head, tail) ->
        ( Executable,
          List.map get_internal_name (head :: tail),
          List.map get_public_name (head :: tail) )
    | Private_executable (head, tail) -> (Executable, head :: tail, [])
    | Test_executable {names = head, tail; _} -> (Executable, head :: tail, [])
  in
  let documentation =
    match internal.documentation with
    | None -> Dune.E
    | Some docs -> Dune.(S "documentation" :: docs)
  in
  Dune.(
    executable_or_library
      kind
      internal_names
      ~public_names
      ?package
      ~instrumentation
      ~libraries
      ?library_flags
      ?link_flags
      ?flags
      ~inline_tests:internal.inline_tests
      ~preprocess
      ~preprocessor_deps
      ~wrapped:internal.wrapped
      ?modules
      ?modules_without_implementation
      ?modes:internal.modes
      ?foreign_stubs:internal.foreign_stubs
      ?c_library_flags:internal.c_library_flags
      ~private_modules:internal.private_modules
      ?js_of_ocaml:internal.js_of_ocaml
    :: documentation :: create_empty_files :: internal.dune)

let static_profile (cclibs : string list) =
  Env.add
    (Profile "static")
    ~key:"flags"
    Dune.
      [
        S ":standard";
        G [S "-ccopt"; S "-static"];
        (match cclibs with
        | [] -> E
        | _ :: _ ->
            let arg =
              List.map (fun lib -> "-l" ^ lib) cclibs |> String.concat " "
            in
            G [S "-cclib"; S arg]);
      ]

(* Remove duplicates from a list.
   Items that are not removed are kept in their original order.
   In case of duplicates, the first occurrence is kept.
   [get_key] returns the comparison key (a string).
   [merge] is used in case a key is present several times. *)
let deduplicate_list ?merge get_key list =
  let add ((list, set) as acc) item =
    let key = get_key item in
    if String_set.mem key set then
      match merge with
      | None -> acc
      | Some merge ->
          (* Go back and merge the previous occurrence. *)
          let merge_if_equal previous_item =
            if String.compare (get_key previous_item) key = 0 then
              merge previous_item item
            else previous_item
          in
          let list = List.map merge_if_equal list in
          (list, set)
    else (item :: list, String_set.add key set)
  in
  List.fold_left add ([], String_set.empty) list |> fst |> List.rev

let generate_dune_files () =
  Target.iter_internal_by_path @@ fun path internals ->
  let has_static =
    List.exists (fun (internal : Target.internal) -> internal.static) internals
  in
  let node_preload =
    List.concat_map
      (fun (internal : Target.internal) ->
        if internal.js_compatible then Target.node_preload internal.deps else [])
      internals
    |> List.sort_uniq compare
  in
  let dunes =
    List.map (generate_dune ~dune_file_has_static_profile:has_static) internals
  in
  write (path // "dune") @@ fun fmt ->
  Format.fprintf
    fmt
    "; This file was automatically generated, do not edit.@.; Edit file \
     manifest/main.ml instead.@.@." ;
  let env = Env.empty in
  let env =
    if has_static then
      let cclibs =
        List.map
          (fun (internal : Target.internal) -> internal.static_cclibs)
          internals
        |> List.flatten |> deduplicate_list Fun.id
      in
      static_profile cclibs env
    else env
  in
  let env =
    match node_preload with
    | [] -> env
    | node_preload ->
        Env.add
          Any
          ~key:"env-vars"
          [S "NODE_PRELOAD"; S (String.concat "," node_preload)]
          env
  in
  let dunes = Dune.[Env.to_s_expr env] :: dunes in
  List.iteri
    (fun i dune ->
      if i <> 0 then Format.fprintf fmt "@." ;
      Format.fprintf fmt "%a@." Dune.pp dune)
    (List.filter (fun x -> not (Dune.is_empty x)) dunes)

(* Convert [target] into an opam dependency so that it can be added as a dependency
   in packages that depend on it.

   [for_package] is the name of the opam package that we are generating
   and in which the dependency will be added.
   If it is the same package as the one in which [target] belongs,
   [None] is returned, since a package cannot depend on itself
   and there is no need to.

   If [fix_version] is [true], require [target]'s version to be
   exactly the same as [for_package]'s version, but only if [target] is internal. *)
let rec as_opam_dependency ~fix_version ~(for_package : string) ~with_test
    (target : Target.t) : Opam.dependency list =
  match target with
  | External {opam = None; _} -> []
  | Internal {opam = Some package; _} ->
      if package = for_package then []
      else
        let version =
          if fix_version then Version.(Exactly Version) else Version.True
        in
        [{Opam.package; version; with_test; optional = false}]
  | Internal ({opam = None; _} as internal) ->
      (* If a target depends on a global "private" target, we must include its dependencies as well *)
      let deps = Target.all_internal_deps internal in
      List.concat_map
        (as_opam_dependency ~fix_version ~for_package ~with_test)
        deps
  | Vendored {name = package; _} ->
      [{Opam.package; version = True; with_test; optional = false}]
  | External {opam = Some opam; version; _}
  | Opam_only {name = opam; version; _} ->
      let version =
        (* FIXME: https://gitlab.com/tezos/tezos/-/issues/1453
           Remove this once all packages (including protocol packages)
           have been ported to the manifest.
           "tezos-rust-libs" is an exception to the exception... *)
        if
          fix_version
          && (has_prefix ~prefix:"tezos-" opam
             || has_prefix ~prefix:"octez-" opam)
          && opam <> "tezos-rust-libs" && opam <> "octez-rust-libs"
        then Version.(Exactly Version)
        else version
      in
      [{Opam.package = opam; version; with_test; optional = false}]
  | Optional target | Select {package = target; _} ->
      List.map
        (fun (dep : Opam.dependency) -> {dep with optional = true})
        (as_opam_dependency ~fix_version ~for_package ~with_test target)
  | Open (target, _) ->
      as_opam_dependency ~fix_version ~for_package ~with_test target

let as_opam_monorepo_opam_provided = function
  | Target.Opam_only {can_vendor = false; name; _} -> Some name
  | _ -> None

let generate_opam ?release for_package (internals : Target.internal list) :
    Opam.t =
  let for_release = release <> None in
  let map l f = List.map f l in
  let depends, x_opam_monorepo_opam_provided =
    List.split @@ map internals
    @@ fun internal ->
    let with_test =
      match internal.kind with Test_executable _ -> Always | _ -> Never
    in
    let deps = Target.all_internal_deps internal in
    let x_opam_monorepo_opam_provided =
      List.filter_map as_opam_monorepo_opam_provided deps
    in
    let deps =
      List.concat_map
        (as_opam_dependency ~fix_version:for_release ~for_package ~with_test)
        deps
    in
    (deps, x_opam_monorepo_opam_provided)
  in
  let depends = List.flatten depends in
  let x_opam_monorepo_opam_provided =
    List.flatten x_opam_monorepo_opam_provided
  in
  let depends =
    match
      List.filter_map
        (fun (internal : Target.internal) -> internal.ocaml)
        internals
    with
    | [] -> depends
    | versions ->
        {
          Opam.package = "ocaml";
          version = Version.and_list versions;
          with_test = Never;
          optional = false;
        }
        :: depends
  in
  let depends =
    {
      Opam.package = "dune";
      version = Version.at_least "3.0";
      with_test = Never;
      optional = false;
    }
    :: depends
  in
  let depends =
    (* Remove duplicate dependencies but when one occurs twice,
       only keep {with-test} if both dependencies had it. *)
    let merge_with_tests a b =
      match (a, b) with
      | Never, _ | _, Never -> Never
      | Always, Always -> Always
      | Only_on_64_arch, Only_on_64_arch -> Only_on_64_arch
      | Only_on_64_arch, Always | Always, Only_on_64_arch ->
          (* Example: a test A depends on a lib L (this is an Always),
             and another test B that can only be ran on 64-bit also depends on lib L
             (this is an Only_on_64_arch). In that case we return Always since the
             dependency is needed for A even on 32-bit. *)
          Always
    in
    let merge (a : Opam.dependency) (b : Opam.dependency) =
      {a with with_test = merge_with_tests a.with_test b.with_test}
    in
    deduplicate_list ~merge (fun {Opam.package; _} -> package) depends
  in
  let conflicts =
    List.flatten @@ map internals
    @@ fun internal ->
    List.concat_map
      (as_opam_dependency ~fix_version:false ~for_package ~with_test:Never)
      internal.conflicts
  in
  let synopsis =
    let all =
      List.filter_map (fun (i : Target.internal) -> i.synopsis) internals
    in
    let () =
      match all with
      | [_] -> ()
      | [] -> error "No synopsis declared for package %s\n" for_package
      | _ :: _ :: _ ->
          error "Too many synopsis declared for package %s\n" for_package
    in
    String.concat " " all
  in
  let description =
    let descriptions =
      List.filter_map Fun.id @@ map internals
      @@ fun internal -> internal.description
    in
    match descriptions with
    | [] -> None
    | descriptions -> Some (String.concat "\n\n" descriptions)
  in
  let build =
    let build : Opam.build_instruction =
      {
        command = [S "dune"; S "build"; S "-p"; A "name"; S "-j"; A "jobs"];
        with_test = Never;
      }
    in
    let with_test =
      match internals with [] -> Never | head :: _ -> head.opam_with_test
    in
    let runtests =
      let get_alias (internal : Target.internal) =
        match internal.kind with
        | Test_executable {runtest_alias; _} -> runtest_alias
        | Public_library _ | Private_library _ | Public_executable _
        | Private_executable _ ->
            None
      in
      let make_runtest alias : Opam.build_instruction list =
        match (with_test, alias) with
        | Never, _ -> []
        | _, "runtest" ->
            (* Special case: Dune has a special command to run this alias. *)
            [
              {
                command =
                  [S "dune"; S "runtest"; S "-p"; A "name"; S "-j"; A "jobs"];
                with_test;
              };
            ]
        | _ ->
            [
              {
                command =
                  [
                    S "dune";
                    S "build";
                    S ("@" ^ alias);
                    S "-p";
                    A "name";
                    S "-j";
                    A "jobs";
                  ];
                with_test;
              };
            ]
      in
      internals |> List.filter_map get_alias
      (* We have to add [runtest] because some targets define the [runtest]
         alias manually and use [~alias:""]. *)
      |> (fun l -> "runtest" :: l)
      |> String_set.of_list |> String_set.elements
      |> List.concat_map make_runtest
    in
    {Opam.command = [S "rm"; S "-r"; S "vendors"]; with_test = Never}
    :: build :: runtests
  in
  let licenses =
    match
      List.filter_map (fun internal -> internal.Target.license) internals
      |> List.sort_uniq String.compare
    with
    | [] -> ["MIT"]
    | licenses -> licenses
  in
  let extra_authors =
    List.concat_map (fun internal -> internal.Target.extra_authors) internals
  in
  {
    maintainer = "contact@tezos.com";
    authors = "Tezos devteam" :: extra_authors;
    homepage = "https://www.tezos.com/";
    bug_reports = "https://gitlab.com/tezos/tezos/issues";
    dev_repo = "git+https://gitlab.com/tezos/tezos.git";
    licenses;
    depends;
    conflicts;
    build;
    synopsis;
    url = Option.map (fun {url; _} -> url) release;
    description;
    x_opam_monorepo_opam_provided;
  }

let generate_opam_files () =
  (* Note:
     - dune files are not always in the same directory of their corresponding .opam
       (usually the .opam is not in a subdir though);
     - there can be multiple .opam in the same directory, for a single dune file
       (or even multiple dune files when some of those dune are in subdirectories).
     So each [Target.t] comes with an [opam] path, which defaults to being in the
     same directory as the dune file, with the package as filename (suffixed with .opam),
     but one can specify a custom .opam path too. *)
  Target.iter_internal_by_opam @@ fun package internals ->
  let opam = generate_opam package internals in
  write ("opam/" ^ package ^ ".opam") @@ fun fmt ->
  Format.fprintf
    fmt
    "# This file was automatically generated, do not edit.@.# Edit file \
     manifest/main.ml instead.@.%a"
    Opam.pp
    opam

let generate_opam_files_for_release packages_dir release =
  Target.iter_internal_by_opam @@ fun package internal_pkgs ->
  let opam_filename =
    packages_dir // package // (package ^ "." ^ release.version) // "opam"
  in
  let opam = generate_opam ~release package internal_pkgs in
  (* We don't use [write] here because we don't want these opam files
     to be considered by the [check_for_non_generated_files] check *)
  write_raw opam_filename @@ fun fmt -> Opam.pp fmt opam

(* Bumping the dune lang version can result in different dune stanza
   semantic and could require changes to the generation logic. *)
let dune_lang_version = "3.0"

let generate_dune_project_files () =
  let t = Hashtbl.create 17 in
  (* Add a dune project at the root *)
  Hashtbl.replace t "" false ;
  (* And one next to every opam files.
     Dune only understand dune files at the root of a dune project. *)
  Target.iter_internal_by_opam (fun package _internals ->
      let cram_enabled =
        Option.value ~default:false (Hashtbl.find_opt t package)
        || List.exists (fun Target.{cram; _} -> cram) _internals
      in
      Hashtbl.replace t (Filename.dirname package) cram_enabled) ;
  write "dune-project" @@ fun fmt ->
  Format.fprintf fmt "(lang dune %s)@." dune_lang_version ;
  Format.fprintf fmt "(formatting (enabled_for ocaml))@." ;
  Format.fprintf fmt "(cram enable)@." ;
  ( Target.iter_internal_by_opam @@ fun package internals ->
    let has_public_target =
      List.exists
        (fun (i : Target.internal) ->
          match i.kind with
          | Public_library _ | Public_executable _ -> true
          | Private_library _ -> false
          | Private_executable _ -> false
          | Test_executable _ -> false)
        internals
    in
    let allow_empty = if not has_public_target then "(allow_empty)" else "" in
    Format.fprintf fmt "(package (name %s)%s)@." package allow_empty ) ;
  Format.fprintf fmt "; This file was automatically generated, do not edit.@." ;
  Format.fprintf fmt "; Edit file manifest/manifest.ml instead.@."

let generate_package_json_file () =
  let l = ref [] in
  let add npm = if not (List.mem npm !l) then l := npm :: !l in
  let rec collect (target : Target.t) =
    match target with
    | External {npm_deps; _} | Vendored {npm_deps; _} | Internal {npm_deps; _}
      ->
        List.iter add npm_deps
    | Optional internal -> collect internal
    | Select {package; _} | Open (package, _) -> collect package
    | Opam_only _ -> ()
  in
  Target.iter_internal_by_path (fun _path internals ->
      List.iter
        (fun (internal : Target.internal) ->
          List.iter add internal.npm_deps ;
          List.iter collect internal.deps)
        internals) ;
  let pp_version_atom fmt = function
    | Version.V x -> Format.fprintf fmt "%s" x
    | Version ->
        invalid_arg "[Version] cannot be used to constrain Npm packages."
  in
  let rec pp_version_constraint ~in_and fmt = function
    | Version.True ->
        invalid_arg "[True] cannot be used to constrain Npm packages."
    | False -> invalid_arg "[False] cannot be used to constrain Npm packages."
    | Not _ -> invalid_arg "[Not] cannot be used to constrain Npm packages."
    | Exactly version -> Format.fprintf fmt "%a" pp_version_atom version
    | Different_from version ->
        Format.fprintf fmt "!= %a" pp_version_atom version
    | At_least version -> Format.fprintf fmt ">=%a" pp_version_atom version
    | More_than version -> Format.fprintf fmt ">%a" pp_version_atom version
    | At_most version -> Format.fprintf fmt "<=%a" pp_version_atom version
    | Less_than version -> Format.fprintf fmt "<%a" pp_version_atom version
    | And (a, b) ->
        Format.fprintf
          fmt
          "%a %a"
          (pp_version_constraint ~in_and:true)
          a
          (pp_version_constraint ~in_and:true)
          b
    | Or (a, b) ->
        if in_and then
          invalid_arg
            "Npm version constraint don't allow [Or] nested inside [And]" ;
        Format.fprintf
          fmt
          "%a || %a"
          (pp_version_constraint ~in_and:false)
          a
          (pp_version_constraint ~in_and:false)
          b
  in
  let pp_dep fmt (npm : Npm.t) =
    Format.fprintf
      fmt
      {|    "%s": "%a"|}
      npm.package
      (pp_version_constraint ~in_and:false)
      npm.version
  in
  write "package.json" @@ fun fmt ->
  Format.fprintf
    fmt
    {|
{
  "DO NOT EDIT": "This file was automatically generated, edit file manifest/main.ml instead",
  "private": true,
  "type": "commonjs",
  "description": "n/a",
  "license": "n/a",
  "dependencies": {
%a
  }
}
|}
    (Format.pp_print_list
       ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@.")
       pp_dep)
    (List.sort compare !l)

let generate_static_packages () =
  write "static-packages" @@ fun fmt ->
  Target.iter_internal_by_opam (fun package internals ->
      if
        List.exists
          (fun (internal : Target.internal) ->
            match internal.kind with
            | Public_executable _ | Private_executable _ -> internal.static
            | Public_library _ | Private_library _ | Test_executable _ -> false)
          internals
      then Format.fprintf fmt "%s\n" package)

let generate_workspace env dune =
  let pp_dune fmt dune =
    if not (Dune.is_empty dune) then Format.fprintf fmt "@.%a@." Dune.pp dune
  in
  write "dune-workspace" @@ fun fmt ->
  Format.fprintf fmt "(lang dune %s)@." dune_lang_version ;
  pp_dune fmt Dune.[Env.to_s_expr env] ;
  pp_dune fmt dune ;
  Format.fprintf fmt "@." ;
  Format.fprintf fmt "; This file was automatically generated, do not edit.@." ;
  Format.fprintf fmt "; Edit file manifest/manifest.ml instead.@."

let find_opam_and_dune_files dir =
  let rec loop prefix acc dir =
    let dir_contents = Sys.readdir (prefix // dir) in
    let add_item acc filename =
      let full_filename = dir // filename in
      if
        filename = "dune"
        || Filename.extension filename = ".opam"
        || filename = "dune-project"
        || filename = "dune-workspace"
      then String_set.add full_filename acc
      else if filename.[0] = '.' || filename.[0] = '_' then acc
      else if
        try Sys.is_directory (prefix // dir // filename)
        with Sys_error _ -> false
      then loop prefix acc full_filename
      else acc
    in
    Array.fold_left add_item acc dir_contents
  in
  loop ".." String_set.empty dir

let check_for_non_generated_files ~remove_extra_files
    ?(exclude = fun _ -> false) () =
  let all_files = find_opam_and_dune_files "" in

  let all_non_excluded_files =
    String_set.filter (fun x -> not (exclude x)) all_files
  in
  let error_generated_and_excluded =
    String_set.filter exclude !generated_files
  in
  String_set.iter
    (error "%s: generated but is excluded\n%!")
    error_generated_and_excluded ;
  let error_not_generated =
    String_set.diff all_non_excluded_files !generated_files
  in
  String_set.iter
    (fun file ->
      if remove_extra_files then (
        info "%s: exists but was not generated, removing it.\n%!" file ;
        Sys.remove (Filename.concat ".." file))
      else error "%s: exists but was not generated\n%!" file)
    error_not_generated ;
  if
    not
      ((remove_extra_files || String_set.is_empty error_not_generated)
      && String_set.is_empty error_generated_and_excluded)
  then
    error
      "Please modify manifest/main.ml to either generate the above file(s)\n\
       or declare them in the 'exclude' function (but not both)."

let check_js_of_ocaml () =
  let internal_name ({kind; path; _} : Target.internal) =
    match kind with
    | Public_library {public_name; _} -> public_name
    | Private_library internal_name -> internal_name
    | Public_executable ({public_name = name; _}, _) -> name
    | Private_executable (name, _) | Test_executable {names = name, _; _} ->
        Filename.concat path name
  in
  let missing_from_target = ref String_map.empty in
  let missing_with_js_mode = ref String_set.empty in
  let missing_jsoo_for_target ~used_by:internal target =
    let name = internal_name internal in
    let old =
      match String_map.find_opt name !missing_from_target with
      | None -> []
      | Some x -> x
    in
    missing_from_target :=
      String_map.add name (target :: old) !missing_from_target
  in
  let missing_jsoo_with_js_mode name =
    missing_with_js_mode := String_set.add name !missing_with_js_mode
  in
  let rec check_target ~used_by (target : Target.t) =
    match target with
    | External {js_compatible; name; _} ->
        if not js_compatible then missing_jsoo_for_target ~used_by name
    | Vendored {js_compatible; name; _} ->
        if not js_compatible then missing_jsoo_for_target ~used_by name
    | Internal ({js_compatible; _} as internal) ->
        if not js_compatible then
          missing_jsoo_for_target ~used_by (internal_name internal)
    | Optional internal -> check_target ~used_by internal
    | Select {package; _} | Open (package, _) -> check_target ~used_by package
    | Opam_only _ -> (* irrelevent to this check *) ()
  in
  let check_internal (internal : Target.internal) =
    if internal.js_compatible then
      List.iter (check_target ~used_by:internal) internal.deps
    else
      match internal.modes with
      | Some modes ->
          if List.mem Dune.JS modes then
            missing_jsoo_with_js_mode (internal_name internal)
      | _ -> ()
  in
  Target.iter_internal_by_path (fun _path internals ->
      List.iter check_internal internals) ;
  let jsoo_ok = ref true in
  if String_set.cardinal !missing_with_js_mode > 0 then (
    jsoo_ok := false ;
    error
      "The following targets use `(modes js)` and are missing \
       `~js_compatible:true`\n" ;
    String_set.iter (fun name -> info "- %s\n" name) !missing_with_js_mode) ;
  if String_map.cardinal !missing_from_target > 0 then (
    jsoo_ok := false ;
    error
      "The following targets are not `~js_compatible` but their dependant \
       expect them to be\n" ;
    String_map.iter
      (fun k v -> List.iter (fun v -> info "- %s used by %s\n" v k) v)
      !missing_from_target)

(* This check returns all circular opam deps, always reporting the
   shortest path.

   For every two targets [A0] and [Ax] in package [A], we search for
   chains of dependencies of the form [A0 -> B0 -> -> Bn -> Ax] where
   [B0 .. Bn] do not belong to Package A. If such paths exist, we
   report one path with the minimum length. *)
let check_circular_opam_deps () =
  let list_iter l f = List.iter f l in
  let name i = Target.name_for_errors (Internal i) in
  let deps_of (t : Target.internal) =
    List.filter_map Target.get_internal (Target.all_internal_deps t)
  in
  Target.iter_internal_by_opam @@ fun this_package internals ->
  let error_header = ref true in
  let report_circular_dep pkg (paths : Target.internal list) =
    if !error_header then (
      error "Circular opam dependency for %s:\n" this_package ;
      error_header := false) ;
    info "- %s\n" (String.concat " -> " (List.map name (pkg :: paths)))
  in
  list_iter internals @@ fun internal_from_this_package ->
  let to_visit : Target.internal Queue.t = Queue.create () in
  let shortest_path : (Target.kind, Target.internal list) Hashtbl.t =
    Hashtbl.create 17
  in
  (* Push to the queue all direct dependencies to other
     packages. Dependencies within the same package are ignored
     because they will never result in a minimum paths. *)
  let () =
    list_iter (deps_of internal_from_this_package)
    @@ fun (dep : Target.internal) ->
    if dep.opam <> Some this_package then (
      Hashtbl.add shortest_path dep.kind [dep] ;
      Queue.push dep to_visit)
  in
  while not (Queue.is_empty to_visit) do
    let elt = Queue.take to_visit in
    let elt_path = Hashtbl.find shortest_path elt.kind in
    list_iter (deps_of elt) (fun (dep : Target.internal) ->
        if not (Hashtbl.mem shortest_path dep.kind) then (
          let path = dep :: elt_path in
          Hashtbl.add shortest_path dep.kind path ;
          if
            dep.opam = Some this_package
            && List.exists
                 (fun (i : Target.internal) ->
                   match (i.opam : string option) with
                   | None ->
                       (* Targets that do not have a package are private and act
                          as if they belonged to all packages.
                          If the shortest path from package A to package A only goes
                          through package A or private packages, it thus only goes
                          through package A and is not a circular dependency. *)
                       false
                   | Some p -> p <> this_package)
                 path
          then report_circular_dep internal_from_this_package (List.rev path)
          else Queue.push dep to_visit))
  done

let check_opam_with_test_consistency () =
  Target.iter_internal_by_opam @@ fun this_package internals ->
  match internals with
  | [] -> ()
  | {opam_with_test = expected; _} :: tail -> (
      match
        List.find_map
          (fun ({opam_with_test; _} : Target.internal) ->
            if opam_with_test <> expected then Some opam_with_test else None)
          tail
      with
      | None -> ()
      | Some bad ->
          error
            "Opam package %s contains targets with different values for \
             ~opam_with_test: %s and %s.\n"
            this_package
            (show_with_test expected)
            (show_with_test bad))

let usage_msg = "Usage: " ^ Sys.executable_name ^ " [OPTIONS]"

let packages_dir, release, remove_extra_files =
  let packages_dir = ref "packages" in
  let url = ref "" in
  let sha256 = ref "" in
  let sha512 = ref "" in
  let remove_extra_files = ref false in
  let version = ref "" in
  let anon_fun _args = () in
  let spec =
    Arg.align
      [
        ( "--packages-dir",
          Arg.Set_string packages_dir,
          "<PATH> Path of the 'packages' directory where to write opam files \
           for release (default: 'packages')" );
        ("--url", Arg.Set_string url, "<URL> Set url for release");
        ("--sha256", Arg.Set_string sha256, "<HASH> Set sha256 for release");
        ("--sha512", Arg.Set_string sha512, "<HASH> Set sha512 for release");
        ( "--release",
          Arg.Set_string version,
          "<VERSION> Generate opam files for release instead, for VERSION" );
        ( "--remove-extra-files",
          Arg.Set remove_extra_files,
          " Remove files that are neither generated nor excluded" );
      ]
  in
  Arg.parse spec anon_fun usage_msg ;
  let release =
    match (!url, !version) with
    | "", "" -> None
    | "", _ | _, "" ->
        prerr_endline
          "Error: either --url and --release must be specified, or none of \
           them." ;
        exit 1
    | url, version ->
        let sha256, sha512 =
          match (!sha256, !sha512, version) with
          | sha256, sha512, "dev" ->
              ( (if sha256 = "" then None else Some sha256),
                if sha512 = "" then None else Some sha512 )
          | "", _, _ | _, "", _ ->
              prerr_endline
                "Error: when making a release other than 'dev', --sha256 and \
                 --sha512 are mandatory." ;
              exit 1
          | sha256, sha512, _ -> (Some sha256, Some sha512)
        in
        Some {version; url = {url; sha256; sha512}}
  in
  (!packages_dir, release, !remove_extra_files)

let generate_opam_ci () =
  let depends_on_unreleased_packages l =
    let rec fold ~seen acc t =
      let name = Target.name_for_errors t in
      if String_set.mem name seen then (seen, acc)
      else
        let seen = String_set.add name seen in
        match t with
        | Vendored {released_on_opam = false; name; _} ->
            (seen, String_set.add name acc)
        | t -> (
            match Target.get_internal t with
            | None -> (seen, acc)
            | Some i ->
                List.fold_left
                  (fun (seen, acc) (t : Target.t) -> fold ~seen acc t)
                  (seen, acc)
                  i.deps)
    in

    List.fold_left
      (fun (seen, acc) (internal : Target.internal) ->
        fold ~seen acc (Internal internal))
      (String_set.empty, String_set.empty)
      l
    |> snd
  in
  let only_test_or_private_targets l =
    List.for_all
      (fun (internal : Target.internal) ->
        match internal.kind with
        | Public_executable _ -> not internal.release
        | Public_library _ -> false
        | Private_executable _ | Private_library _ -> true
        | Test_executable _ -> true)
      l
  in
  (* [deps] maps a package name to its (internal) opam deps. *)
  let deps : (string, Opam.dependency list) Hashtbl.t = Hashtbl.create 17 in
  Target.iter_internal_by_opam (fun package_name internal_pkgs ->
      let opam_deps =
        internal_pkgs
        |> List.concat_map (fun i ->
               Target.all_internal_deps i
               |> List.filter_map Target.get_internal
               |> List.map (fun i -> Target.Internal i)
               |> List.concat_map
                    (as_opam_dependency
                       ~fix_version:false
                       ~for_package:package_name
                       ~with_test:Never))
        |> deduplicate_list
             ~merge:(fun a _b -> a)
             (fun {Opam.package; _} -> package)
      in
      Hashtbl.add deps package_name opam_deps) ;
  (* [rank] is used to perform a topological sort. A package should
     receive a rank higher than all its dependencies. *)
  let rank : (string, int) Hashtbl.t = Hashtbl.create 17 in
  let rec compute_rank (name : string) : int =
    match Hashtbl.find_opt rank name with
    | Some rank -> rank
    | None ->
        let deps = Hashtbl.find deps name in
        let max_rank =
          deps
          |> List.map (fun (opam_dep : Opam.dependency) ->
                 compute_rank opam_dep.package)
          |> List.fold_left max 0
        in
        Hashtbl.replace rank name (max_rank + 1) ;
        max_rank + 1
  in
  Target.iter_internal_by_opam (fun package_name _internal_pkgs ->
      let (_ : int) = compute_rank package_name in
      ()) ;
  write ".gitlab/ci/opam-ci.yml" @@ fun fmt ->
  Format.fprintf fmt "# This file was automatically generated, do not edit.@." ;
  Format.fprintf fmt "# Edit file manifest/manifest.ml instead.@." ;
  (* Decide whether an opam package should be tested in the CI or
     not. If not, remove it from [rank] so that we do not consider it in
     the later stage. *)
  Target.iter_internal_by_opam (fun package_name internal_pkgs ->
      if only_test_or_private_targets internal_pkgs then (
        Hashtbl.remove rank package_name ;
        Format.fprintf
          fmt
          "@.# Ignoring package %s, it only contains tests or private targets\n"
          package_name)
      else
        let unreleased = depends_on_unreleased_packages internal_pkgs in
        if not (String_set.is_empty unreleased) then (
          Hashtbl.remove rank package_name ;
          Format.fprintf
            fmt
            "@.# Ignoring package %s, it depends on vendored packages\n\
             # that do not exists inside the official opam-repository:\n"
            package_name ;
          String_set.iter (Format.fprintf fmt "# - %s\n") unreleased)) ;

  let template d =
    Format.fprintf
      fmt
      {|@..rules_template__trigger_opam_batch_%d:
  rules:
    # Run on scheduled builds.
    - if: '$TZ_PIPELINE_KIND == "SCHEDULE" && $TZ_SCHEDULE_KIND == "EXTENDED_TESTS"'
      when: delayed
      start_in: %d minutes
    # Never run on branch pipelines for master.
    - if: '$CI_COMMIT_BRANCH == $TEZOS_DEFAULT_BRANCH'
      when: never
    # Run when there is label on the merge request
    - if: '$CI_MERGE_REQUEST_LABELS =~ /(?:^|[,])ci--opam(?:$|[,])/'
      when: delayed
      start_in: %d minutes
    # Run on merge requests when opam changes are detected.
    - if: '$CI_MERGE_REQUEST_ID'
      changes:
        - "**/dune"
        - "**/dune.inc"
        - "**/*.dune.inc"
        - "**/dune-project"
        - "**/dune-workspace"
        - "**/*.opam"
        - .gitlab/ci/opam-ci.yml
        - .gitlab/ci/packaging.yml
        - manifest/manifest.ml
        - scripts/opam-prepare-repo.sh
        - scripts/version.sh
      when: delayed
      start_in: %d minutes
    - when: never # default
|}
      d
      d
      d
      d
  in
  for i = 1 to (Hashtbl.length rank / 30) + 1 do
    template i
  done ;
  (* We setup one job per opam package and have around 200 packages.
     Due to technical limitations of the CI, we want to avoid starting
     that many jobs at the same time.  Gitlab allows to delay a job
     using `when:delayed` and `start_in:SPAN`.  We start multiple
     small batch of opam jobs leaving few seconds/minutes between them. *)
  Hashtbl.fold (fun name rank acc -> (name, rank) :: acc) rank []
  (* We sort elements in descending rank order. The goal is to assign
     smaller delay to packages with the most dependencies (as the job should take longer to run). *)
  |> List.sort (fun (n1, r1) (n2, r2) ->
         match compare (r2 : int) r1 with
         | 0 -> compare (n1 : string) n2
         | c -> c)
  |> List.mapi (fun i (name, _) ->
         (* group jobs by 30, delay each group by 1 minute *)
         let delayed_by = 1 + (i / 30) in
         (name, delayed_by))
  (* We sort elements by name because we don't want the jobs to move around when topological sort changes *)
  |> List.sort (fun (n1, _) (n2, _) -> compare (n1 : string) n2)
  |> List.iter (fun (package_name, delayed_by) ->
         Format.fprintf
           fmt
           {|@.opam:%s:
  extends:
    - .opam_template
    - .rules_template__trigger_opam_batch_%d
  variables:
    package: %s
|}
           package_name
           delayed_by
           package_name)

let generate ~make_tezt_exe =
  Printexc.record_backtrace true ;
  try
    register_tezt_targets ~make_tezt_exe ;
    generate_dune_files () ;
    generate_opam_files () ;
    generate_dune_project_files () ;
    generate_package_json_file () ;
    generate_static_packages () ;
    generate_opam_ci () ;
    Option.iter (generate_opam_files_for_release packages_dir) release
  with exn ->
    Printexc.print_backtrace stderr ;
    prerr_endline ("Error: " ^ Printexc.to_string exn) ;
    exit 1

let check ?exclude () =
  if !checks_done then failwith "Cannot run check twice" ;
  checks_done := true ;
  Printexc.record_backtrace true ;
  try
    check_circular_opam_deps () ;
    check_for_non_generated_files ~remove_extra_files ?exclude () ;
    check_js_of_ocaml () ;
    check_opam_with_test_consistency () ;
    if !has_error then exit 1
  with exn ->
    Printexc.print_backtrace stderr ;
    prerr_endline ("Error: " ^ Printexc.to_string exn) ;
    exit 1

include Target

let name_for_errors = function
  | None -> "(no target)"
  | Some target -> name_for_errors target
