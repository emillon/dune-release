(*---------------------------------------------------------------------------
   Copyright (c) 2016 Daniel C. Bünzli. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

open Bos_setup
open Dune_release

let get_pkg_dir pkg =
  Pkg.build_dir pkg >>= fun bdir ->
  Pkg.distrib_opam_path pkg >>= fun fname -> Ok Fpath.(bdir // fname)

let rec descr = function
  | [] -> Ok 0
  | h :: t ->
      Pkg.opam_descr h >>= fun d ->
      Logs.app (fun m -> m "%s" (Opam.Descr.to_string d));
      if t <> [] then Logs.app (fun m -> m "---\n");
      descr t

module D = struct
  let distrib_uri = "${distrib_uri}"
end

let remove_generated_dune_comment opam =
  let sep = "# This file is generated by dune, edit dune-project instead\n" in
  match Astring.String.cut ~sep opam with Some ("", opam) -> opam | _ -> opam

let write_opam_file ~dry_run ~id ~url ~opam_f pkg dest_opam_file =
  OS.File.read opam_f >>= fun opam ->
  let filename = OpamFilename.of_string (Fpath.filename dest_opam_file) in
  let opam_t = OpamFile.OPAM.read_from_string opam in
  match OpamVersion.to_string (OpamFile.OPAM.opam_version opam_t) with
  | "2.0" ->
      let file x = OpamFile.make (OpamFilename.of_string (Fpath.to_string x)) in
      let opam_t = Opam_file.upgrade ~filename ~url ~id opam_t ~version:`V2 in
      let opam =
        OpamFile.OPAM.to_string_with_preserved_format ~format_from:(file opam_f)
          (file dest_opam_file) opam_t
        |> remove_generated_dune_comment
      in
      Sos.write_file ~dry_run dest_opam_file opam
  | ("1.0" | "1.1" | "1.2") as v ->
      App_log.unhappy (fun l -> l "%s" Deprecate.Opam_1_x.file_format_warning);
      App_log.status (fun l ->
          l "Upgrading opam file %a from opam format %s to 2.0" Text.Pp.path
            opam_f v);
      Pkg.opam_descr pkg >>= fun descr ->
      let descr =
        OpamFile.Descr.read_from_string (Opam.Descr.to_string descr)
      in
      let opam =
        Opam_file.upgrade ~filename ~url ~id opam_t ~version:(`V1 descr)
        |> OpamFile.OPAM.write_to_string
      in
      Sos.write_file ~dry_run dest_opam_file opam
  | s -> Fmt.kstr (fun x -> Error (`Msg x)) "invalid opam version: %s" s

let archive_url ~dry_run ~opam_file pkg =
  Pkg.archive_url_path pkg >>= fun url_file ->
  OS.File.exists url_file >>= fun url_file_exists ->
  OS.Path.exists opam_file >>= fun opam_file_exists ->
  if url_file_exists then Sos.read_file ~dry_run url_file
  else if dry_run && not opam_file_exists then Ok D.distrib_uri
  else (
    Logs.warn (fun l -> l "Could not find %a." Text.Pp.path url_file);
    Pkg.infer_github_distrib_uri pkg >>= fun uri ->
    Logs.warn (fun l ->
        l
          "using %s for as url.src. Note that it might differ from the one \
           generated by Github"
          uri);
    Ok uri)

let pkg ~dry_run ~distrib_uri pkg =
  let warn_if_vcs_dirty () =
    Cli.warn_if_vcs_dirty
      "The opam package may be inconsistent with the distribution."
  in
  Pkg.name pkg >>= fun pkg_name ->
  App_log.status (fun l ->
      l "Creating opam package description for %a" Text.Pp.name pkg_name);
  get_pkg_dir pkg >>= fun dir ->
  Pkg.opam pkg >>= fun opam_f ->
  Pkg.distrib_file ~dry_run pkg >>= fun distrib_file ->
  (match distrib_uri with
  | Some uri -> Ok uri
  | None -> archive_url ~dry_run ~opam_file:opam_f pkg)
  >>= fun uri ->
  let uri = String.trim uri in
  Opam.Url.with_distrib_file ~dry_run ~uri distrib_file >>= fun url ->
  OS.Dir.exists dir >>= fun exists ->
  (if exists then Sos.delete_dir ~dry_run dir else Ok ()) >>= fun () ->
  OS.Dir.create dir >>= fun _ ->
  let dest_opam_file = Fpath.(dir / "opam") in
  Vcs.get () >>= fun repo ->
  Vcs.commit_id repo ~dirty:false ~commit_ish:"HEAD" >>= fun id ->
  write_opam_file ~dry_run ~id ~url ~opam_f pkg dest_opam_file >>= fun () ->
  App_log.success (fun m ->
      m "Wrote opam package description %a" Text.Pp.path dest_opam_file);
  if not dry_run then warn_if_vcs_dirty () else Ok ()

let rec list_map f = function
  | [] -> Ok []
  | h :: t ->
      f h >>= fun h ->
      list_map f t >>= fun t -> Ok (h :: t)

let pp_opam_repo fmt opam_repo =
  let user, repo = opam_repo in
  Format.fprintf fmt "%s/%s" user repo

let open_pr ~dry_run ~changes ~remote_repo ~fork_owner ~branch ~token ~title
    ~opam_repo ~auto_open ~yes ~draft pkg =
  Pkg.opam_descr pkg >>= fun (syn, _) ->
  Pkg.opam_homepage pkg >>= fun homepage ->
  Pkg.opam_doc pkg >>= fun doc ->
  let pp_link name ppf = function
    | None -> ()
    | Some h -> Fmt.pf ppf "- %s: <a href=%S>%s</a>\n" name h h
  in
  let pp_space ppf () =
    if homepage <> None || doc <> None then Fmt.string ppf "\n"
  in
  let msg =
    strf "%s\n\n%a%a%a##### %s" syn (pp_link "Project page") homepage
      (pp_link "Documentation") doc pp_space () changes
  in
  Prompt.(
    confirm_or_abort ~yes
      ~question:(fun l ->
        l "Open %a to %a?" Text.Pp.maybe_draft (draft, "PR") pp_opam_repo
          opam_repo)
      ~default_answer:Yes)
  >>= fun () ->
  App_log.status (fun l ->
      l "Opening %a to merge branch %a of %a into %a" Text.Pp.maybe_draft
        (draft, "pull request") Text.Pp.commit branch Text.Pp.url remote_repo
        pp_opam_repo opam_repo);
  Github.open_pr ~token ~dry_run ~title ~fork_owner ~branch ~opam_repo ~draft
    msg pkg
  >>= function
  | `Already_exists ->
      App_log.blank_line ();
      App_log.success (fun l ->
          l "The existing pull request for %a has been automatically updated."
            Fmt.(styled `Bold string)
            (fork_owner ^ ":" ^ branch));
      Ok 0
  | `Url url -> (
      let msg () =
        App_log.success (fun m ->
            m "A new %a has been created at %s\n" Text.Pp.maybe_draft
              (draft, "pull-request") url);
        Ok 0
      in
      if not auto_open then msg ()
      else
        let auto_open =
          if OpamStd.Sys.(os () = Darwin) then "open" else "xdg-open"
        in
        match Sos.run ~dry_run Cmd.(v auto_open % url) with
        | Ok () -> Ok 0
        | Error _ -> msg ())

let parse_remote_repo remote_repo =
  match Github_repo.from_uri remote_repo with
  | Some repo -> Ok repo
  | None ->
      R.error_msgf
        "The URL to your remote fork of opam-repository %s does not seem to \
         point to a github repo.\n\
         Try editing your config with `dune-release config set remote <URL>` \
         or providing a valid Github repo URL via the --remote-repo option."
        remote_repo

let submit ~token ~dry_run ~yes ~opam_repo ~pkgs_to_submit local_repo
    remote_repo pkgs auto_open ~draft =
  List.fold_left
    (fun acc pkg ->
      get_pkg_dir pkg >>= fun pkg_dir ->
      Sos.dir_exists ~dry_run pkg_dir >>= function
      | true -> acc
      | false ->
          Logs.err (fun m ->
              m
                "Package %a does not exist. Did you forget to invoke \
                 'dune-release opam pkg' ?"
                Fpath.pp pkg_dir);
          Ok 1)
    (Ok 0) pkgs
  >>= fun _ ->
  let pkg = Pkg.main pkgs in
  Pkg.version pkg >>= fun version ->
  Pkg.tag pkg >>= fun tag ->
  Pkg.build_dir pkg >>= fun build_dir ->
  Pkg.name pkg >>= fun name ->
  let project_name = Pkg.project_name pkg in
  (if draft then Ok ()
   else
     match Config.Draft_release.is_set ~dry_run ~build_dir ~name ~version with
     | Ok true ->
         R.error_msg
           "Cannot open a non-draft pull request for a draft release. Please \
            use option '--draft' for 'dune-release opam submit'."
     | _ -> Ok ())
  >>= fun () ->
  list_map Pkg.name pkgs >>= fun names ->
  let title = Github.pr_title ~names ~version ~project_name ~pkgs_to_submit in
  Pkg.publish_msg pkg >>= fun changes ->
  let gh_repo = Rresult.R.to_option (Pkg.infer_github_repo pkg) in
  let changes =
    match gh_repo with
    | Some { owner; repo } -> Text.rewrite_github_refs ~user:owner ~repo changes
    | None -> changes
  in
  parse_remote_repo remote_repo >>= fun { owner = fork_owner; _ } ->
  let msg = strf "%s\n\n%s\n" title changes in
  App_log.status (fun l ->
      l "Preparing %a to %a" Text.Pp.maybe_draft (draft, "pull request")
        pp_opam_repo opam_repo);
  Opam.prepare ~dry_run ~msg ~local_repo ~remote_repo ~opam_repo ~version ~tag
    ~project_name names
  >>= fun branch ->
  open_pr ~dry_run ~changes ~remote_repo ~fork_owner ~branch ~token ~title
    ~opam_repo ~auto_open ~yes ~draft pkg

let field pkgs field =
  match field with
  | None ->
      Logs.err (fun m -> m "Missing FIELD positional argument");
      Ok 1
  | Some field ->
      let rec loop = function
        | [] -> Ok 0
        | h :: t -> (
            Pkg.opam_field h field >>= function
            | Some v ->
                Logs.app (fun m -> m "%s" (String.concat ~sep:" " v));
                loop t
            | None ->
                Pkg.opam h >>= fun opam ->
                Logs.err (fun m ->
                    m "%a: field %s is undefined" Fpath.pp opam field);
                Ok 1)
      in
      loop pkgs

(* Command *)

let get_pkgs ?build_dir ?opam ?distrib_file ?readme ?change_log ?publish_msg
    ?pkg_descr ~dry_run ~keep_v ~tag ~pkg_names ~version () =
  Config.keep_v ~keep_v >>= fun keep_v ->
  let distrib_file =
    let pkg =
      Pkg.v ?opam ?tag ?version ?distrib_file ~dry_run:false ~keep_v ()
    in
    Pkg.distrib_file ~dry_run pkg
  in
  Pkg.infer_pkg_names Fpath.(v ".") pkg_names >>= fun pkg_names ->
  let pkg_names = List.map (fun n -> Some n) pkg_names in
  distrib_file >>| fun distrib_file ->
  List.map
    (fun name ->
      Pkg.v ~dry_run ?build_dir ?name ?version ?opam ?tag ?opam_descr:pkg_descr
        ~keep_v ~distrib_file ?readme ?change_log ?publish_msg ())
    pkg_names

let descr ~pkgs = descr pkgs

let pkg ?distrib_uri ~dry_run ~pkgs () =
  List.fold_left
    (fun acc p ->
      match (acc, pkg ~dry_run ~distrib_uri p) with
      | Ok i, Ok () -> Ok i
      | (Error _ as e), _ | _, (Error _ as e) -> e)
    (Ok 0) pkgs

let report_user_option_use user =
  match user with
  | None -> ()
  | Some _ -> App_log.unhappy (fun l -> l "%s" Deprecate.Config_user.option_use)

let submit ?local_repo:local ?remote_repo:remote ?opam_repo ?user ?token
    ~dry_run ~pkgs ~pkg_names ~no_auto_open ~yes ~draft () =
  let opam_repo =
    match opam_repo with None -> ("ocaml", "opam-repository") | Some r -> r
  in
  report_user_option_use user;
  Config.token ~token ~dry_run () >>= fun token ->
  Config.opam_repo_fork ~pkgs ~local ~remote () >>= fun { remote; local } ->
  Config.auto_open ~no_auto_open >>= fun auto_open ->
  App_log.status (fun m ->
      m "Submitting %a" Fmt.(list ~sep:sp Text.Pp.name) pkg_names);
  submit ~token ~dry_run ~yes ~opam_repo ~pkgs_to_submit:pkg_names local remote
    pkgs auto_open ~draft

let field ~pkgs ~field_name = field pkgs field_name

let opam_cli () (`Dry_run dry_run) (`Build_dir build_dir)
    (`Local_repo local_repo) (`Remote_repo remote_repo) (`Opam_repo opam_repo)
    (`User user) (`Keep_v keep_v) (`Dist_opam opam) (`Dist_uri distrib_uri)
    (`Dist_file distrib_file) (`Dist_tag tag) (`Package_names pkg_names)
    (`Package_version version) (`Pkg_descr pkg_descr) (`Readme readme)
    (`Change_log change_log) (`Publish_msg publish_msg) (`Action action)
    (`Field_name field_name) (`No_auto_open no_auto_open) (`Yes yes)
    (`Token token) (`Draft draft) =
  get_pkgs ?build_dir ?opam ?distrib_file ?pkg_descr ?readme ?change_log
    ?publish_msg ~dry_run ~keep_v ~tag ~pkg_names ~version ()
  >>= (fun pkgs ->
        match action with
        | `Descr -> descr ~pkgs
        | `Pkg -> pkg ~dry_run ?distrib_uri ~pkgs ()
        | `Submit ->
            submit ?local_repo ?remote_repo ?opam_repo ?user ?token ~dry_run
              ~pkgs ~pkg_names ~no_auto_open ~yes ~draft ()
        | `Field -> field ~pkgs ~field_name)
  |> Cli.handle_error

(* Command line interface *)

open Cmdliner

let action =
  let action =
    [ ("descr", `Descr); ("pkg", `Pkg); ("submit", `Submit); ("field", `Field) ]
  in
  let doc =
    strf "The action to perform. $(docv) must be one of %s."
      (Arg.doc_alts_enum action)
  in
  let action = Arg.enum action in
  Cli.named
    (fun x -> `Action x)
    Arg.(required & pos 0 (some action) None & info [] ~doc ~docv:"ACTION")

let field_arg =
  let doc = "the field to output ($(b,field) action)" in
  Cli.named
    (fun x -> `Field_name x)
    Arg.(value & pos 1 (some string) None & info [] ~doc ~docv:"FIELD")

let pkg_descr =
  let doc =
    "The opam descr file to use for the opam package. If absent and the opam \
     file name (see $(b,--pkg-opam)) has a `.opam` extension, uses an existing \
     file with the same path but a `.descr` extension. If the opam file name \
     is `opam` uses a `descr` file in the same directory. If these files are \
     not found a description is extracted from the the readme (see option \
     $(b,--readme)) as follow: the first marked up section of the readme is \
     extracted, its title is parsed according to the pattern '\\$(NAME) \
     \\$(SEP) \\$(SYNOPSIS)', the body of the section is the long description. \
     A few lines are filtered out: lines that start with either 'Home page:', \
     'Contact:' or '%%VERSION'."
  in
  let docv = "FILE" in
  Cli.named
    (fun x -> `Pkg_descr x)
    Arg.(value & opt (some Cli.path_arg) None & info [ "pkg-descr" ] ~doc ~docv)

let doc = "Interaction with opam and the OCaml opam repository"
let sdocs = Manpage.s_common_options
let envs = []
let man_xrefs = [ `Main; `Cmd "distrib" ]

let man =
  [
    `S Manpage.s_synopsis;
    `P "$(mname) $(tname) [$(i,OPTION)]... $(i,ACTION)";
    `S Manpage.s_description;
    `P
      "The $(tname) command provides a few actions to interact with opam and \
       the OCaml opam repository.";
    `S "ACTIONS";
    `I
      ( "$(b,descr)",
        "extract and print an opam descr file. This is used by the $(b,pkg) \
         action. See the $(b,--pkg-descr) option for details." );
    `I
      ( "$(b,pkg)",
        "create an opam package description for a distribution. The action \
         needs a distribution archive to operate, see dune-release-distrib(1) \
         or the $(b,--dist-file) option." );
    `I
      ( "$(b,submit)",
        "submits a package created with the action $(b,pkg) the OCaml opam \
         repository. This requires configuration to be created manually first, \
         see $(i, dune-release help files) for more details." );
    `I
      ( "$(b,field) $(i,FIELD)",
        "outputs the field $(i,FIELD) of the package's opam file." );
  ]

let info = Cmd.info "opam" ~doc ~sdocs ~envs ~man ~man_xrefs

let term =
  Term.(
    const opam_cli $ Cli.setup $ Cli.dry_run $ Cli.build_dir $ Cli.local_repo
    $ Cli.remote_repo $ Cli.opam_repo $ Cli.user $ Cli.keep_v $ Cli.dist_opam
    $ Cli.dist_uri $ Cli.dist_file $ Cli.dist_tag $ Cli.pkg_names
    $ Cli.pkg_version $ pkg_descr $ Cli.readme $ Cli.change_log
    $ Cli.publish_msg $ action $ field_arg $ Cli.no_auto_open $ Cli.yes
    $ Cli.token $ Cli.draft)

let cmd = Cmd.v info term

(*---------------------------------------------------------------------------
   Copyright (c) 2016 Daniel C. Bünzli

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
