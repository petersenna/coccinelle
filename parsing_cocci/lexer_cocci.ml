# 0 "lexer_cocci.mll"
 
open Parser_cocci_menhir
module D = Data
module Ast = Ast_cocci
module Ast0 = Ast0_cocci
module P = Parse_aux
module FC = Flag_parsing_cocci
exception Lexical of string
let tok = Lexing.lexeme

let line = ref 1
let logical_line = ref 0

(* ---------------------------------------------------------------------- *)
(* control codes *)

(* Defined in data.ml
type line_type = MINUS | OPTMINUS | UNIQUEMINUS | PLUS | CONTEXT | UNIQUE | OPT
*)

let current_line_type = ref (D.CONTEXT,!line,!logical_line)

let prev_plus = ref false
let line_start = ref 0 (* offset of the beginning of the line *)
let get_current_line_type lexbuf =
  let (c,l,ll) = !current_line_type in
  let lex_start = Lexing.lexeme_start lexbuf in
  let preceeding_spaces =
    if !line_start < 0 then 0 else lex_start - !line_start in
  (*line_start := -1;*)
  prev_plus := (c = D.PLUS) or (c = D.PLUSPLUS);
  (c,l,ll,lex_start,preceeding_spaces,[],[],[])
let current_line_started = ref false
let col_zero = ref true

let contextify (c,l,ll,lex_start,preceeding_spaces,bef,aft,pos) =
  (D.CONTEXT,l,ll,lex_start,preceeding_spaces,bef,aft,pos)

let reset_line lexbuf =
  line := !line + 1;
  current_line_type := (D.CONTEXT,!line,!logical_line);
  current_line_started := false;
  col_zero := true;
  line_start := Lexing.lexeme_start lexbuf + 1

let started_line = ref (-1)

let start_line seen_char =
  current_line_started := true;
  col_zero := false;
  (if seen_char && not(!line = !started_line)
  then
    begin
      started_line := !line;
      logical_line := !logical_line + 1
    end)

let pass_zero _ = col_zero := false

let lexerr s1 s2 = raise (Lexical (Printf.sprintf "%s%s" s1 s2))

let opt_reverse_token token =
  if !FC.interpret_inverted
  then match token with
         D.MINUS        -> D.PLUSPLUS  (* maybe too liberal *)
       | D.OPTMINUS     -> lexerr "cannot invert token ?- (an optional minus line), which is needed for reversing the patch" ""  
       | D.UNIQUEMINUS  -> D.PLUS
       | D.PLUS         -> D.MINUS
       | D.PLUSPLUS     -> D.MINUS (* may not be sufficient *)
       | _              -> token
  else token

let add_current_line_type x =
  match (opt_reverse_token x,!current_line_type) with
    (D.MINUS,(D.CONTEXT,ln,lln))  ->
      current_line_type := (D.MINUS,ln,lln)
  | (D.MINUS,(D.UNIQUE,ln,lln))   ->
      current_line_type := (D.UNIQUEMINUS,ln,lln)
  | (D.MINUS,(D.OPT,ln,lln))      ->
      current_line_type := (D.OPTMINUS,ln,lln)
  | (D.PLUS,(D.CONTEXT,ln,lln))   ->
      current_line_type := (D.PLUS,ln,lln)
  | (D.PLUSPLUS,(D.CONTEXT,ln,lln))   ->
      current_line_type := (D.PLUSPLUS,ln,lln)
  | (D.UNIQUE,(D.CONTEXT,ln,lln)) ->
      current_line_type := (D.UNIQUE,ln,lln)
  | (D.OPT,(D.CONTEXT,ln,lln))    ->
      current_line_type := (D.OPT,ln,lln)
  | _ -> lexerr "invalid control character combination" ""

let check_minus_context_linetype s =
  match !current_line_type with
    (D.PLUS,_,_) | (D.PLUSPLUS,_,_) -> lexerr "invalid in a + context: " s
  | _ -> ()

let check_context_linetype s =
  match !current_line_type with
    (D.CONTEXT,_,_) -> ()
  | _ -> lexerr "invalid in a nonempty context: " s

let check_plus_linetype s =
  match !current_line_type with
    (D.PLUS,_,_) | (D.PLUSPLUS,_,_) -> ()
  | _ -> lexerr "invalid in a non + context: " s

let check_arity_context_linetype s =
  match !current_line_type with
    (D.CONTEXT,_,_) | (D.PLUS,_,_) | (D.PLUSPLUS,_,_)
  | (D.UNIQUE,_,_) | (D.OPT,_,_) -> ()
  | _ -> lexerr "invalid in a nonempty context: " s

let check_comment s =
  if not !current_line_started
  then lexerr "+ expected at the beginning of the line" s

let process_include start finish str =
  (match !current_line_type with
    (D.PLUS,_,_) | (D.PLUSPLUS,_,_) ->
      (try
	let _ = Str.search_forward (Str.regexp "\\.\\.\\.") str start in
	lexerr "... not allowed in + include" ""
      with Not_found -> ())
  | _ -> ());
  String.sub str (start + 1) (finish - start - 1)

(* ---------------------------------------------------------------------- *)
type pm = PATCH | MATCH | UNKNOWN

let pm = ref UNKNOWN

let patch_or_match = function
    PATCH ->
      if not !D.ignore_patch_or_match
      then
	(match !pm with
	  MATCH ->
	    lexerr "- or + not allowed in the first column for a match" ""
	| PATCH -> ()
	| UNKNOWN -> Flag.sgrep_mode2 := false; pm := PATCH)
  | MATCH ->
      if not !D.ignore_patch_or_match
      then
	(match !pm with
	  PATCH -> lexerr "* not allowed in the first column for a patch" ""
	| MATCH -> ()
	| UNKNOWN -> Flag.sgrep_mode2 := true; pm := MATCH)
  | _ -> failwith "unexpected argument"

(* ---------------------------------------------------------------------- *)
(* identifiers, including metavariables *)

let metavariables = (Hashtbl.create(100) : (string, D.clt -> token) Hashtbl.t)

let all_metavariables =
  (Hashtbl.create(100) : (string,(string * (D.clt -> token)) list) Hashtbl.t)

let type_names = (Hashtbl.create(100) : (string, D.clt -> token) Hashtbl.t)

let declarer_names = (Hashtbl.create(100) : (string, D.clt -> token) Hashtbl.t)

let iterator_names = (Hashtbl.create(100) : (string, D.clt -> token) Hashtbl.t)

let symbol_names = (Hashtbl.create(15) : (string, D.clt -> token) Hashtbl.t)

let rule_names = (Hashtbl.create(100) : (string, unit) Hashtbl.t)

let check_var s linetype =
  let fail _ =
    if (!Data.in_prolog || !Data.in_rule_name) &&
      Str.string_match (Str.regexp "<.*>") s 0
    then TPathIsoFile s
    else
      try (Hashtbl.find metavariables s) linetype
      with Not_found ->
	(try (Hashtbl.find type_names s) linetype
	with Not_found ->
	  (try (Hashtbl.find declarer_names s) linetype
	  with Not_found ->
	    (try (Hashtbl.find iterator_names s) linetype
	    with Not_found ->
	      (try (Hashtbl.find symbol_names s) linetype
	      with Not_found ->
                TIdent (s,linetype))))) in
  if !Data.in_meta or !Data.in_rule_name
  then (try Hashtbl.find rule_names s; TRuleName s with Not_found -> fail())
  else fail()

let id_tokens lexbuf =
  let s = tok lexbuf in
  let linetype = get_current_line_type lexbuf in
  let in_rule_name = !Data.in_rule_name in
  let in_meta = !Data.in_meta && not !Data.saw_struct in
  let in_iso = !Data.in_iso in
  let in_prolog = !Data.in_prolog in
  (if s = "identifer" && in_meta
  then Common.pr2 "Warning: should identifer be identifier?");
  match s with
    "metavariable" when in_meta -> check_arity_context_linetype s; TMetavariable
  | "identifier" when in_meta -> check_arity_context_linetype s; TIdentifier
  | "type" when in_meta ->       check_arity_context_linetype s; TType
  | "parameter" when in_meta ->  check_arity_context_linetype s; TParameter
  | "constant"  when in_meta ->  check_arity_context_linetype s; TConstant
  | "generated" when in_rule_name && not (!Flag.make_hrule = None) ->
      check_arity_context_linetype s; TGenerated
  | "expression" when in_meta || in_rule_name ->
      check_arity_context_linetype s; TExpression
  | "declaration" when in_meta || in_rule_name ->
      check_arity_context_linetype s; TDeclaration
  | "field" when in_meta || in_rule_name ->
      check_arity_context_linetype s; TField
  | "initialiser" when in_meta || in_rule_name ->
      check_arity_context_linetype s; TInitialiser
  | "initializer" when in_meta || in_rule_name ->
      check_arity_context_linetype s; TInitialiser
  | "idexpression" when in_meta ->
      check_arity_context_linetype s; TIdExpression
  | "statement" when in_meta ->  check_arity_context_linetype s; TStatement
  | "function"  when in_meta ->  check_arity_context_linetype s; TFunction
  | "local" when in_meta ->      check_arity_context_linetype s; TLocal
  | "list" when in_meta ->       check_arity_context_linetype s; Tlist
  | "fresh" when in_meta ->      check_arity_context_linetype s; TFresh
  | "typedef" when in_meta ->    check_arity_context_linetype s; TTypedef
  | "declarer" when in_meta ->   check_arity_context_linetype s; TDeclarer
  | "iterator" when in_meta ->   check_arity_context_linetype s; TIterator
  | "name" when in_meta ->       check_arity_context_linetype s; TName
  | "position" when in_meta ->   check_arity_context_linetype s; TPosition
  | "any" when in_meta ->        check_arity_context_linetype s; TPosAny
  | "pure" when in_meta && in_iso ->
      check_arity_context_linetype s; TPure
  | "context" when in_meta && in_iso ->
      check_arity_context_linetype s; TContext
  | "error" when in_meta ->      check_arity_context_linetype s; TError
  | "words" when in_meta ->      check_context_linetype s; TWords
  | "symbol" when in_meta ->     check_arity_context_linetype s; TSymbol

  | "using" when in_rule_name || in_prolog ->  check_context_linetype s; TUsing
  | "virtual" when in_prolog or in_rule_name or in_meta ->
      (* don't want to allow virtual as a rule name *)
      check_context_linetype s; TVirtual
  | "disable" when in_rule_name ->  check_context_linetype s; TDisable
  | "extends" when in_rule_name -> check_context_linetype s; TExtends
  | "depends" when in_rule_name -> check_context_linetype s; TDepends
  | "on" when in_rule_name      -> check_context_linetype s; TOn
  | "ever" when in_rule_name    -> check_context_linetype s; TEver
  | "never" when in_rule_name   -> check_context_linetype s; TNever
  (* exists and forall for when are reparsed in parse_cocci.ml *)
  | "exists" when in_rule_name  -> check_context_linetype s; TExists
  | "forall" when in_rule_name  -> check_context_linetype s; TForall
  | "script" when in_rule_name  -> check_context_linetype s; TScript
  | "initialize" when in_rule_name -> check_context_linetype s; TInitialize
  | "finalize" when in_rule_name   -> check_context_linetype s; TFinalize

  | "char" ->       Tchar     linetype
  | "short" ->      Tshort    linetype
  | "int" ->        Tint      linetype
  | "double" ->     Tdouble   linetype
  | "float" ->      Tfloat    linetype
  | "long" ->       Tlong     linetype
  | "void" ->       Tvoid     linetype
  | "size_t" ->     Tsize_t   linetype
  | "ssize_t" ->    Tssize_t  linetype
  | "ptrdiff_t" ->  Tptrdiff_t linetype
  (* in_meta is only for the first keyword; drop it now to allow any type
     name *)
  | "struct" ->     Data.saw_struct := true; Tstruct   linetype
  | "union" ->      Data.saw_struct := true; Tunion    linetype
  | "enum" ->       Data.saw_struct := true; Tenum     linetype
  | "unsigned" ->   Tunsigned linetype
  | "signed" ->     Tsigned   linetype

  | "auto"  ->      Tauto     linetype
  | "register" ->   Tregister linetype
  | "extern" ->     Textern   linetype
  | "static" ->     Tstatic   linetype
  | "inline" ->     Tinline   linetype
  | "typedef" ->    Ttypedef  linetype

  | "const" ->      Tconst    linetype
  | "volatile" ->   Tvolatile linetype

  | "if" ->         TIf       linetype
  | "else" ->       TElse     linetype
  | "while" ->      TWhile    linetype
  | "do" ->         TDo       linetype
  | "for" ->        TFor      linetype
  | "switch" ->     TSwitch   linetype
  | "case" ->       TCase     linetype
  | "default" ->    TDefault  linetype
  | "return" ->     TReturn   linetype
  | "break" ->      TBreak    linetype
  | "continue" ->   TContinue linetype
  | "goto" ->       TGoto     linetype

  | "sizeof" ->     TSizeof   linetype

  | "Expression"       when !Data.in_iso -> TIsoExpression
  | "ArgExpression"    when !Data.in_iso -> TIsoArgExpression
  | "TestExpression"   when !Data.in_iso -> TIsoTestExpression
  | "ToTestExpression" when !Data.in_iso -> TIsoToTestExpression
  | "Statement"        when !Data.in_iso -> TIsoStatement
  | "Declaration"      when !Data.in_iso -> TIsoDeclaration
  | "Type"             when !Data.in_iso -> TIsoType
  | "TopLevel"         when !Data.in_iso -> TIsoTopLevel

  | "_" when !Data.in_meta -> TUnderscore

  | s -> check_var s linetype

let mkassign op lexbuf =
  TAssign (Ast.OpAssign op, (get_current_line_type lexbuf))

let init _ =
  line := 1;
  logical_line := 0;
  prev_plus := false;
  line_start := 0;
  current_line_started := false;
  current_line_type := (D.CONTEXT,0,0);
  col_zero := true;
  pm := UNKNOWN;
  Data.in_rule_name := false;
  Data.in_meta := false;
  Data.in_prolog := false;
  Data.saw_struct := false;
  Data.inheritable_positions := [];
  Hashtbl.clear all_metavariables;
  Hashtbl.clear Data.all_metadecls;
  Hashtbl.clear metavariables;
  Hashtbl.clear type_names;
  Hashtbl.clear rule_names;
  Hashtbl.clear iterator_names;
  Hashtbl.clear declarer_names;
  Hashtbl.clear symbol_names;
  let get_name (_,x) = x in
  Data.add_meta_meta :=
    (fun name pure ->
      let fn clt = TMeta(name,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_id_meta :=
    (fun name constraints pure ->
      let fn clt = TMetaId(name,constraints,Ast.NoVal,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_virt_id_meta_found :=
    (fun name vl ->
      let fn clt = TIdent(vl,clt) in
      Hashtbl.replace metavariables name fn);
  Data.add_virt_id_meta_not_found :=
    (fun name pure ->
      let fn clt = TMetaId(name,Ast.IdNoConstraint,Ast.NoVal,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_fresh_id_meta :=
    (fun name seed ->
      let fn clt = TMetaId(name,Ast.IdNoConstraint,seed,Ast0.Impure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_type_meta :=
    (fun name pure ->
      let fn clt = TMetaType(name,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_init_meta :=
    (fun name pure ->
      let fn clt = TMetaInit(name,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_initlist_meta :=
    (function name -> function lenname -> function pure ->
      let fn clt = TMetaInitList(name,lenname,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_param_meta :=
    (function name -> function pure ->
      let fn clt = TMetaParam(name,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_paramlist_meta :=
    (function name -> function lenname -> function pure ->
      let fn clt = TMetaParamList(name,lenname,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_const_meta :=
    (fun tyopt name constraints pure ->
      let fn clt = TMetaConst(name,constraints,pure,tyopt,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_err_meta :=
    (fun name constraints pure ->
      let fn clt = TMetaErr(name,constraints,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_exp_meta :=
    (fun tyopt name constraints pure ->
      let fn clt = TMetaExp(name,constraints,pure,tyopt,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_idexp_meta :=
    (fun tyopt name constraints pure ->
      let fn clt = TMetaIdExp(name,constraints,pure,tyopt,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_local_idexp_meta :=
    (fun tyopt name constraints pure ->
      let fn clt = TMetaLocalIdExp(name,constraints,pure,tyopt,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_explist_meta :=
    (function name -> function lenname -> function pure ->
      let fn clt = TMetaExpList(name,lenname,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_decl_meta :=
    (function name -> function pure ->
      let fn clt = TMetaDecl(name,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_field_meta :=
    (function name -> function pure ->
      let fn clt = TMetaField(name,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_field_list_meta :=
    (function name -> function lenname -> function pure ->
      let fn clt = TMetaFieldList(name,lenname,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_stm_meta :=
    (function name -> function pure ->
      let fn clt = TMetaStm(name,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_stmlist_meta :=
    (function name -> function pure ->
      let fn clt = TMetaStmList(name,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_func_meta :=
    (fun name constraints pure ->
      let fn clt = TMetaFunc(name,constraints,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_local_func_meta :=
    (fun name constraints pure ->
      let fn clt = TMetaLocalFunc(name,constraints,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_iterator_meta :=
    (fun name constraints pure ->
      let fn clt = TMetaIterator(name,constraints,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_declarer_meta :=
    (fun name constraints pure ->
      let fn clt = TMetaDeclarer(name,constraints,pure,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_pos_meta :=
    (fun name constraints any ->
      let fn ((d,ln,_,_,_,_,_,_) as clt) =
	(if d = Data.PLUS
	then
	  failwith
	    (Printf.sprintf "%d: positions only allowed in minus code" ln));
	TMetaPos(name,constraints,any,clt) in
      Hashtbl.replace metavariables (get_name name) fn);
  Data.add_type_name :=
    (function name ->
      let fn clt = TTypeId(name,clt) in
      Hashtbl.replace type_names name fn);
  Data.add_declarer_name :=
    (function name ->
      let fn clt = TDeclarerId(name,clt) in
      Hashtbl.replace declarer_names name fn);
  Data.add_iterator_name :=
    (function name ->
      let fn clt = TIteratorId(name,clt) in
      Hashtbl.replace iterator_names name fn);
  Data.add_symbol_meta :=
    (function name ->
      let fn clt = TSymId (name,clt) in
      Hashtbl.replace symbol_names name fn);
  Data.init_rule := (function _ -> Hashtbl.clear metavariables);
  Data.install_bindings :=
    (function parent ->
      List.iter (function (name,fn) -> Hashtbl.add metavariables name fn)
	(Hashtbl.find all_metavariables parent))

(* the following is needed to properly tokenize include files.  Because an
include file is included after seeing a @, so current_line_started is true.
Current_line_started is not important for parsing the name of a rule, so we
don't have to reset this value to true after parsing an included file. *)
let include_init _ =
  current_line_started := false

let drop_spaces s =
  let len = String.length s in
  let rec loop n =
    if n = len
    then n
    else
      if List.mem (String.get s n) [' ';'\t']
      then loop (n+1)
      else n in
  let start = loop 0 in
  String.sub s start (len - start)

# 487 "lexer_cocci.ml"
let __ocaml_lex_tables = {
  Lexing.lex_base = 
   "\000\000\170\255\171\255\081\000\119\000\176\255\177\255\192\000\
    \023\001\052\001\038\000\078\000\067\000\103\000\220\255\081\000\
    \082\000\224\255\225\255\228\255\229\255\230\255\231\255\233\255\
    \084\000\106\000\237\255\239\255\101\000\116\000\140\000\122\001\
    \144\001\231\001\087\000\090\000\085\000\062\002\138\000\255\255\
    \176\002\106\000\146\000\186\255\213\255\096\000\159\002\246\002\
    \077\003\164\003\251\003\082\004\169\004\000\005\087\005\174\005\
    \005\006\092\006\206\006\115\000\170\000\117\000\119\000\149\000\
    \037\007\101\000\124\007\211\007\013\008\100\008\158\008\105\000\
    \055\000\245\008\126\000\129\000\076\009\163\009\133\000\250\009\
    \081\010\139\010\226\010\251\255\172\255\205\255\249\255\204\255\
    \248\255\057\011\144\011\231\011\062\012\149\012\134\001\146\000\
    \150\000\132\000\244\255\242\255\148\002\220\001\051\002\134\000\
    \136\000\157\000\159\000\160\000\245\255\163\000\165\000\243\255\
    \208\255\173\255\216\255\169\000\227\255\205\000\215\255\174\000\
    \208\000\232\255\234\255\236\255\198\255\210\255\214\255\212\255\
    \199\255\211\255\209\255\203\255\158\000\207\255\207\012\038\013\
    \163\000\096\013\183\013\164\000\014\014\101\014\159\014\246\014\
    \118\000\110\000\121\000\123\000\125\000\122\000\122\006\193\255\
    \134\000\136\000\136\000\053\001\104\015\179\015\149\000\148\000\
    \144\000\154\000\054\001\037\016\120\016\190\255\017\015\184\000\
    \176\000\168\000\186\000\187\000\209\006\216\001\034\001\036\001\
    \189\255\225\002\188\255\153\001\114\002\116\002\203\002\155\001\
    \208\002\205\002\156\001\202\000\220\000\043\001\219\000\221\000\
    \027\002\028\002\218\000\223\000\115\002\227\000\000\001\201\002\
    \018\001\013\001\038\001\053\001\202\002\041\001\053\001\209\002\
    \038\015\130\001\195\016\241\003\119\007\068\009\222\016\071\004\
    \158\004\036\017\219\001\174\255\067\001\255\255\080\015\252\255\
    \106\017\069\003\245\004\254\255\129\017\253\255\228\005\254\255\
    \010\016\255\255\251\255\167\017\076\005\163\005\253\255\190\017\
    \252\255\231\005\254\255\043\016\255\255\251\255\228\017\250\005\
    \084\006\253\255\251\017\252\255\046\004\252\255\253\255\254\255\
    \108\001\255\255";
  Lexing.lex_backtrk = 
   "\255\255\255\255\255\255\081\000\081\000\255\255\255\255\073\000\
    \072\000\085\000\049\000\055\000\061\000\060\000\255\255\034\000\
    \032\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \020\000\085\000\255\255\255\255\015\000\014\000\054\000\029\000\
    \072\000\072\000\017\000\038\000\005\000\072\000\033\000\255\255\
    \001\000\255\255\002\000\255\255\255\255\255\255\255\255\072\000\
    \072\000\072\000\072\000\072\000\072\000\072\000\072\000\072\000\
    \072\000\072\000\072\000\255\255\255\255\255\255\255\255\003\000\
    \255\255\075\000\255\255\076\000\255\255\074\000\255\255\255\255\
    \255\255\255\255\074\000\255\255\255\255\255\255\076\000\255\255\
    \076\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\072\000\072\000\008\000\072\000\072\000\080\000\255\255\
    \009\000\255\255\255\255\255\255\255\255\080\000\255\255\053\000\
    \059\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\037\000\255\255\070\000\255\255\036\000\
    \071\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\058\000\255\255\255\255\077\000\
    \255\255\255\255\255\255\077\000\255\255\077\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\063\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\064\000\255\255\068\000\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\068\000\068\000\068\000\068\000\068\000\
    \068\000\068\000\068\000\255\255\255\255\255\255\255\255\255\255\
    \068\000\068\000\255\255\255\255\068\000\255\255\255\255\068\000\
    \255\255\255\255\255\255\255\255\068\000\255\255\255\255\068\000\
    \081\000\081\000\255\255\080\000\255\255\255\255\081\000\080\000\
    \255\255\081\000\081\000\255\255\255\255\255\255\000\000\255\255\
    \003\000\001\000\001\000\255\255\002\000\255\255\255\255\255\255\
    \001\000\255\255\255\255\004\000\002\000\002\000\255\255\003\000\
    \255\255\255\255\255\255\001\000\255\255\255\255\004\000\002\000\
    \002\000\255\255\003\000\255\255\255\255\255\255\255\255\255\255\
    \004\000\255\255";
  Lexing.lex_default = 
   "\001\000\000\000\000\000\255\255\255\255\000\000\000\000\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\000\000\255\255\
    \255\255\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \255\255\255\255\000\000\000\000\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\000\000\
    \255\255\255\255\042\000\000\000\000\000\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\061\000\061\000\061\000\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\000\000\000\000\000\000\000\000\000\000\
    \000\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\000\000\000\000\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\000\000\255\255\255\255\000\000\
    \000\000\000\000\000\000\255\255\000\000\117\000\000\000\255\255\
    \120\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\255\255\000\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\000\000\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\000\000\179\000\255\255\
    \255\255\255\255\255\255\255\255\255\255\177\000\175\000\175\000\
    \000\000\177\000\000\000\179\000\179\000\179\000\179\000\183\000\
    \179\000\179\000\186\000\255\255\255\255\255\255\255\255\255\255\
    \192\000\193\000\255\255\255\255\196\000\255\255\255\255\199\000\
    \255\255\255\255\255\255\255\255\204\000\255\255\255\255\207\000\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\000\000\221\000\000\000\223\000\000\000\
    \255\255\255\255\255\255\000\000\255\255\000\000\231\000\000\000\
    \234\000\000\000\000\000\255\255\255\255\255\255\000\000\255\255\
    \000\000\242\000\000\000\245\000\000\000\000\000\255\255\255\255\
    \255\255\000\000\255\255\000\000\253\000\000\000\000\000\000\000\
    \255\255\000\000";
  Lexing.lex_trans = 
   "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\040\000\039\000\039\000\039\000\039\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \040\000\034\000\005\000\009\000\007\000\015\000\013\000\006\000\
    \026\000\023\000\016\000\028\000\018\000\029\000\031\000\038\000\
    \004\000\003\000\003\000\003\000\003\000\003\000\003\000\003\000\
    \003\000\003\000\010\000\017\000\030\000\035\000\011\000\027\000\
    \036\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\033\000\
    \008\000\008\000\008\000\022\000\025\000\021\000\012\000\037\000\
    \134\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\032\000\
    \008\000\008\000\008\000\020\000\024\000\019\000\014\000\211\000\
    \130\000\003\000\003\000\003\000\003\000\003\000\003\000\003\000\
    \003\000\003\000\003\000\131\000\132\000\128\000\127\000\126\000\
    \119\000\125\000\123\000\121\000\087\000\083\000\212\000\085\000\
    \084\000\042\000\066\000\061\000\255\255\208\000\062\000\045\000\
    \063\000\115\000\118\000\072\000\129\000\211\000\209\000\214\000\
    \214\000\214\000\214\000\214\000\214\000\214\000\214\000\213\000\
    \213\000\114\000\116\000\060\000\043\000\068\000\212\000\105\000\
    \071\000\042\000\106\000\079\000\212\000\208\000\063\000\075\000\
    \096\000\097\000\099\000\208\000\113\000\112\000\209\000\044\000\
    \104\000\103\000\060\000\109\000\209\000\107\000\108\000\210\000\
    \124\000\110\000\059\000\111\000\098\000\088\000\117\000\255\255\
    \086\000\120\000\255\255\133\000\212\000\140\000\136\000\205\000\
    \200\000\166\000\158\000\208\000\007\000\189\000\122\000\188\000\
    \152\000\167\000\153\000\187\000\209\000\154\000\155\000\210\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\045\000\159\000\046\000\160\000\161\000\162\000\
    \002\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\168\000\169\000\170\000\171\000\007\000\
    \172\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\007\000\197\000\150\000\156\000\163\000\
    \194\000\193\000\192\000\195\000\255\255\196\000\176\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\045\000\198\000\046\000\150\000\156\000\163\000\151\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\199\000\201\000\202\000\255\255\008\000\255\255\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\255\255\203\000\190\000\255\255\204\000\206\000\
    \148\000\146\000\207\000\001\001\000\000\147\000\191\000\222\000\
    \144\000\000\000\000\000\255\255\145\000\255\255\255\255\000\000\
    \095\000\149\000\094\000\094\000\094\000\094\000\094\000\094\000\
    \094\000\094\000\094\000\094\000\007\000\000\000\094\000\094\000\
    \094\000\094\000\094\000\094\000\094\000\094\000\094\000\094\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\045\000\100\000\046\000\255\255\218\000\000\000\
    \255\255\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\100\000\000\000\000\000\218\000\008\000\
    \000\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \092\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\007\000\101\000\101\000\101\000\101\000\
    \101\000\101\000\101\000\101\000\101\000\101\000\255\255\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\045\000\255\255\046\000\255\255\255\255\255\255\219\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\089\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\000\000\255\255\000\000\000\000\008\000\219\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\007\000\101\000\101\000\101\000\101\000\101\000\
    \101\000\101\000\101\000\101\000\101\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \045\000\000\000\046\000\000\000\255\255\255\255\255\255\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\255\255\000\000\255\255\255\255\047\000\000\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\040\000\039\000\039\000\039\000\039\000\000\000\102\000\
    \000\000\102\000\000\000\064\000\101\000\101\000\101\000\101\000\
    \101\000\101\000\101\000\101\000\101\000\101\000\000\000\000\000\
    \040\000\000\000\000\000\255\255\255\255\255\255\184\000\255\255\
    \255\255\182\000\255\255\255\255\000\000\000\000\000\000\041\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\000\000\000\000\000\000\000\000\064\000\000\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\007\000\255\255\255\255\064\000\000\000\178\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \045\000\183\000\046\000\186\000\000\000\185\000\000\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\000\000\000\000\000\000\000\000\008\000\000\000\048\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\007\000\255\255\255\255\255\255\226\000\226\000\226\000\
    \226\000\226\000\226\000\226\000\226\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\045\000\
    \000\000\046\000\000\000\000\000\000\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \000\000\000\000\000\000\000\000\008\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\049\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \007\000\255\255\255\255\255\255\000\000\255\255\000\000\000\000\
    \255\255\255\255\000\000\000\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\045\000\000\000\
    \046\000\255\255\000\000\000\000\000\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\000\000\
    \000\000\000\000\000\000\008\000\000\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \050\000\008\000\008\000\008\000\008\000\008\000\008\000\007\000\
    \000\000\211\000\211\000\211\000\211\000\211\000\211\000\211\000\
    \211\000\211\000\211\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\045\000\100\000\046\000\
    \255\000\255\000\255\000\255\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\100\000\000\000\
    \000\001\254\000\008\000\000\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\051\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\007\000\215\000\
    \215\000\215\000\215\000\215\000\215\000\215\000\215\000\215\000\
    \215\000\000\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\045\000\000\000\046\000\000\000\
    \000\000\000\000\000\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\000\000\000\000\000\000\
    \000\000\008\000\000\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\052\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\007\000\215\000\215\000\
    \215\000\215\000\215\000\215\000\215\000\215\000\215\000\215\000\
    \000\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\045\000\000\000\046\000\000\000\000\000\
    \000\000\000\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\000\000\000\000\000\000\000\000\
    \008\000\000\000\008\000\053\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\007\000\227\000\227\000\227\000\
    \227\000\227\000\227\000\227\000\227\000\000\000\255\255\000\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\045\000\000\000\046\000\000\000\000\000\000\000\
    \000\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\000\000\000\000\000\000\000\000\008\000\
    \000\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\054\000\008\000\008\000\
    \008\000\008\000\008\000\007\000\237\000\237\000\237\000\237\000\
    \237\000\237\000\237\000\237\000\000\000\000\000\000\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\045\000\000\000\046\000\000\000\000\000\000\000\000\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\000\000\000\000\000\000\000\000\008\000\000\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\055\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\007\000\238\000\238\000\238\000\238\000\238\000\
    \238\000\238\000\238\000\000\000\000\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \045\000\000\000\046\000\000\000\000\000\000\000\000\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\244\000\000\000\233\000\000\000\008\000\000\000\008\000\
    \008\000\008\000\008\000\056\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\007\000\248\000\248\000\248\000\248\000\248\000\248\000\
    \248\000\248\000\000\000\000\000\000\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\045\000\
    \232\000\046\000\000\000\243\000\000\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \000\000\000\000\000\000\000\000\057\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \007\000\000\000\000\000\150\000\249\000\249\000\249\000\249\000\
    \249\000\249\000\249\000\249\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\045\000\000\000\
    \046\000\000\000\150\000\000\000\000\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\000\000\
    \000\000\000\000\000\000\058\000\000\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\060\000\
    \000\000\000\000\172\000\000\000\000\000\000\000\148\000\146\000\
    \000\000\000\000\000\000\147\000\255\255\000\000\144\000\255\255\
    \000\000\000\000\145\000\000\000\000\000\000\000\060\000\149\000\
    \000\000\172\000\007\000\174\000\000\000\000\000\059\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \045\000\000\000\046\000\000\000\000\000\173\000\000\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\000\000\000\000\000\000\000\000\008\000\000\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\064\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\000\000\
    \000\000\000\000\000\000\065\000\000\000\000\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \000\000\000\000\000\000\000\000\064\000\000\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \067\000\000\000\216\000\064\000\216\000\000\000\000\000\215\000\
    \215\000\215\000\215\000\215\000\215\000\215\000\215\000\215\000\
    \215\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\000\000\
    \000\000\000\000\000\000\067\000\000\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \000\000\000\000\068\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\075\000\000\000\076\000\
    \000\000\000\000\000\000\000\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\000\000\000\000\
    \000\000\069\000\067\000\000\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \000\000\000\000\000\000\000\000\069\000\000\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\071\000\000\000\
    \070\000\000\000\000\000\000\000\000\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\000\000\
    \000\000\000\000\073\000\069\000\000\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\000\000\000\000\000\000\000\000\073\000\000\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\000\000\000\000\073\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\000\000\
    \000\000\000\000\000\000\074\000\000\000\000\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \000\000\000\000\000\000\000\000\073\000\000\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \077\000\000\000\211\000\073\000\213\000\213\000\213\000\213\000\
    \213\000\213\000\213\000\213\000\213\000\213\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\212\000\000\000\000\000\000\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\000\000\
    \000\000\212\000\000\000\077\000\000\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \000\000\000\000\077\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\000\000\000\000\000\000\
    \000\000\078\000\000\000\000\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\000\000\000\000\
    \000\000\000\000\077\000\000\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\080\000\000\000\
    \000\000\077\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\000\000\000\000\000\000\
    \000\000\080\000\000\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\075\000\000\000\081\000\000\000\000\000\
    \000\000\000\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\000\000\000\000\000\000\082\000\
    \080\000\000\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\000\000\000\000\
    \000\000\000\000\082\000\000\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\000\000\
    \000\000\082\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\000\000\000\000\000\000\000\000\
    \078\000\000\000\000\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\000\000\000\000\000\000\
    \000\000\082\000\000\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\007\000\000\000\000\000\
    \082\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\045\000\000\000\046\000\000\000\000\000\
    \000\000\000\000\008\000\008\000\008\000\008\000\090\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\000\000\000\000\000\000\000\000\
    \008\000\000\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\007\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\045\000\000\000\046\000\000\000\000\000\000\000\
    \000\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\091\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\000\000\000\000\000\000\000\000\008\000\
    \000\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\007\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\045\000\000\000\046\000\000\000\000\000\000\000\000\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\000\000\000\000\000\000\000\000\008\000\000\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\007\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \045\000\000\000\046\000\000\000\000\000\000\000\000\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\000\000\000\000\000\000\000\000\008\000\000\000\008\000\
    \008\000\008\000\008\000\093\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\007\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\045\000\
    \000\000\046\000\000\000\000\000\000\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \000\000\000\000\000\000\135\000\008\000\000\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\091\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\000\000\000\000\000\000\000\000\135\000\000\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \136\000\000\000\137\000\000\000\000\000\000\000\000\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\000\000\000\000\000\000\138\000\135\000\000\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\000\000\000\000\000\000\000\000\138\000\
    \000\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\000\000\000\000\138\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\000\000\000\000\000\000\000\000\139\000\000\000\000\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\000\000\000\000\000\000\000\000\138\000\000\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\141\000\000\000\000\000\138\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\000\000\000\000\000\000\000\000\141\000\000\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\136\000\
    \000\000\142\000\000\000\000\000\000\000\000\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \000\000\000\000\000\000\143\000\141\000\000\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\000\000\000\000\000\000\000\000\143\000\000\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\255\255\000\000\143\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \000\000\000\000\000\000\000\000\139\000\000\000\000\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\000\000\000\000\000\000\000\000\143\000\000\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\156\000\219\000\000\000\143\000\181\000\000\000\000\000\
    \000\000\000\000\000\000\219\000\000\000\000\000\000\000\180\000\
    \225\000\225\000\225\000\225\000\225\000\225\000\225\000\225\000\
    \156\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\219\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\219\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\000\000\000\000\000\000\000\000\157\000\
    \224\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\000\000\000\000\
    \000\000\255\255\157\000\000\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\163\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\236\000\236\000\236\000\236\000\236\000\236\000\
    \236\000\236\000\000\000\000\000\000\000\163\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \255\255\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\247\000\247\000\247\000\247\000\247\000\
    \247\000\247\000\247\000\000\000\000\000\000\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \000\000\000\000\235\000\000\000\164\000\000\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \165\000\000\000\000\000\246\000\000\000\000\000\000\000\000\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\000\000\000\000\000\000\000\000\164\000\
    \000\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\217\000\217\000\217\000\217\000\217\000\
    \217\000\217\000\217\000\217\000\217\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\217\000\217\000\217\000\217\000\
    \217\000\217\000\255\255\000\000\211\000\000\000\214\000\214\000\
    \214\000\214\000\214\000\214\000\214\000\214\000\213\000\213\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\212\000\217\000\217\000\217\000\217\000\
    \217\000\217\000\208\000\255\255\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\209\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\212\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\208\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\209\000\217\000\217\000\217\000\217\000\
    \217\000\217\000\217\000\217\000\217\000\217\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\217\000\217\000\217\000\
    \217\000\217\000\217\000\000\000\000\000\000\000\000\000\000\000\
    \208\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\209\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\217\000\217\000\217\000\
    \217\000\217\000\217\000\000\000\000\000\000\000\000\000\000\000\
    \208\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\209\000\228\000\228\000\228\000\228\000\228\000\228\000\
    \228\000\228\000\228\000\228\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\228\000\228\000\228\000\228\000\228\000\
    \228\000\229\000\229\000\229\000\229\000\229\000\229\000\229\000\
    \229\000\229\000\229\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\229\000\229\000\229\000\229\000\229\000\229\000\
    \000\000\000\000\000\000\228\000\228\000\228\000\228\000\228\000\
    \228\000\000\000\000\000\000\000\000\000\000\000\000\000\239\000\
    \239\000\239\000\239\000\239\000\239\000\239\000\239\000\239\000\
    \239\000\000\000\229\000\229\000\229\000\229\000\229\000\229\000\
    \239\000\239\000\239\000\239\000\239\000\239\000\240\000\240\000\
    \240\000\240\000\240\000\240\000\240\000\240\000\240\000\240\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\240\000\
    \240\000\240\000\240\000\240\000\240\000\000\000\000\000\000\000\
    \239\000\239\000\239\000\239\000\239\000\239\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\250\000\250\000\250\000\250\000\
    \250\000\250\000\250\000\250\000\250\000\250\000\000\000\240\000\
    \240\000\240\000\240\000\240\000\240\000\250\000\250\000\250\000\
    \250\000\250\000\250\000\251\000\251\000\251\000\251\000\251\000\
    \251\000\251\000\251\000\251\000\251\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\251\000\251\000\251\000\251\000\
    \251\000\251\000\000\000\000\000\000\000\250\000\250\000\250\000\
    \250\000\250\000\250\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\251\000\251\000\251\000\251\000\
    \251\000\251\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000";
  Lexing.lex_check = 
   "\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\000\000\000\000\000\000\000\000\000\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \010\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\003\000\
    \012\000\003\000\003\000\003\000\003\000\003\000\003\000\003\000\
    \003\000\003\000\003\000\011\000\011\000\013\000\015\000\016\000\
    \028\000\024\000\025\000\025\000\034\000\036\000\003\000\035\000\
    \035\000\041\000\045\000\059\000\042\000\003\000\061\000\065\000\
    \062\000\029\000\028\000\071\000\013\000\004\000\003\000\004\000\
    \004\000\004\000\004\000\004\000\004\000\004\000\004\000\004\000\
    \004\000\029\000\029\000\060\000\038\000\072\000\003\000\030\000\
    \074\000\038\000\030\000\075\000\004\000\003\000\063\000\078\000\
    \095\000\096\000\097\000\004\000\103\000\104\000\003\000\038\000\
    \030\000\030\000\060\000\105\000\004\000\106\000\107\000\004\000\
    \024\000\109\000\060\000\110\000\096\000\034\000\115\000\117\000\
    \035\000\119\000\120\000\132\000\004\000\136\000\139\000\144\000\
    \145\000\147\000\148\000\004\000\007\000\146\000\025\000\146\000\
    \149\000\147\000\152\000\146\000\004\000\153\000\154\000\004\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\158\000\007\000\159\000\160\000\161\000\
    \000\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\167\000\168\000\169\000\170\000\007\000\
    \171\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\007\000\007\000\007\000\007\000\007\000\
    \007\000\007\000\007\000\008\000\187\000\009\000\155\000\162\000\
    \188\000\190\000\191\000\194\000\174\000\195\000\175\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\197\000\008\000\009\000\155\000\162\000\009\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\198\000\200\000\201\000\061\000\008\000\062\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\008\000\008\000\008\000\008\000\008\000\008\000\
    \008\000\008\000\042\000\202\000\189\000\063\000\203\000\205\000\
    \009\000\009\000\206\000\000\001\255\255\009\000\189\000\220\000\
    \009\000\255\255\255\255\179\000\009\000\183\000\186\000\255\255\
    \031\000\009\000\031\000\031\000\031\000\031\000\031\000\031\000\
    \031\000\031\000\031\000\031\000\032\000\255\255\094\000\094\000\
    \094\000\094\000\094\000\094\000\094\000\094\000\094\000\094\000\
    \032\000\032\000\032\000\032\000\032\000\032\000\032\000\032\000\
    \032\000\032\000\032\000\094\000\032\000\117\000\209\000\255\255\
    \120\000\032\000\032\000\032\000\032\000\032\000\032\000\032\000\
    \032\000\032\000\032\000\032\000\032\000\032\000\032\000\032\000\
    \032\000\032\000\032\000\032\000\032\000\032\000\032\000\032\000\
    \032\000\032\000\032\000\094\000\255\255\255\255\209\000\032\000\
    \255\255\032\000\032\000\032\000\032\000\032\000\032\000\032\000\
    \032\000\032\000\032\000\032\000\032\000\032\000\032\000\032\000\
    \032\000\032\000\032\000\032\000\032\000\032\000\032\000\032\000\
    \032\000\032\000\032\000\033\000\101\000\101\000\101\000\101\000\
    \101\000\101\000\101\000\101\000\101\000\101\000\173\000\033\000\
    \033\000\033\000\033\000\033\000\033\000\033\000\033\000\033\000\
    \033\000\033\000\174\000\033\000\175\000\192\000\193\000\218\000\
    \033\000\033\000\033\000\033\000\033\000\033\000\033\000\033\000\
    \033\000\033\000\033\000\033\000\033\000\033\000\033\000\033\000\
    \033\000\033\000\033\000\033\000\033\000\033\000\033\000\033\000\
    \033\000\033\000\255\255\220\000\255\255\255\255\033\000\218\000\
    \033\000\033\000\033\000\033\000\033\000\033\000\033\000\033\000\
    \033\000\033\000\033\000\033\000\033\000\033\000\033\000\033\000\
    \033\000\033\000\033\000\033\000\033\000\033\000\033\000\033\000\
    \033\000\033\000\037\000\102\000\102\000\102\000\102\000\102\000\
    \102\000\102\000\102\000\102\000\102\000\255\255\037\000\037\000\
    \037\000\037\000\037\000\037\000\037\000\037\000\037\000\037\000\
    \037\000\255\255\037\000\255\255\180\000\196\000\181\000\037\000\
    \037\000\037\000\037\000\037\000\037\000\037\000\037\000\037\000\
    \037\000\037\000\037\000\037\000\037\000\037\000\037\000\037\000\
    \037\000\037\000\037\000\037\000\037\000\037\000\037\000\037\000\
    \037\000\179\000\255\255\183\000\186\000\037\000\255\255\037\000\
    \037\000\037\000\037\000\037\000\037\000\037\000\037\000\037\000\
    \037\000\037\000\037\000\037\000\037\000\037\000\037\000\037\000\
    \037\000\037\000\037\000\037\000\037\000\037\000\037\000\037\000\
    \037\000\040\000\040\000\040\000\040\000\040\000\255\255\100\000\
    \255\255\100\000\255\255\046\000\100\000\100\000\100\000\100\000\
    \100\000\100\000\100\000\100\000\100\000\100\000\255\255\255\255\
    \040\000\255\255\255\255\199\000\204\000\182\000\180\000\185\000\
    \173\000\181\000\184\000\207\000\255\255\255\255\255\255\040\000\
    \046\000\046\000\046\000\046\000\046\000\046\000\046\000\046\000\
    \046\000\046\000\046\000\046\000\046\000\046\000\046\000\046\000\
    \046\000\046\000\046\000\046\000\046\000\046\000\046\000\046\000\
    \046\000\046\000\255\255\255\255\255\255\255\255\046\000\255\255\
    \046\000\046\000\046\000\046\000\046\000\046\000\046\000\046\000\
    \046\000\046\000\046\000\046\000\046\000\046\000\046\000\046\000\
    \046\000\046\000\046\000\046\000\046\000\046\000\046\000\046\000\
    \046\000\046\000\047\000\192\000\193\000\046\000\255\255\177\000\
    \255\255\255\255\255\255\255\255\255\255\255\255\047\000\047\000\
    \047\000\047\000\047\000\047\000\047\000\047\000\047\000\047\000\
    \047\000\182\000\047\000\185\000\255\255\184\000\255\255\047\000\
    \047\000\047\000\047\000\047\000\047\000\047\000\047\000\047\000\
    \047\000\047\000\047\000\047\000\047\000\047\000\047\000\047\000\
    \047\000\047\000\047\000\047\000\047\000\047\000\047\000\047\000\
    \047\000\255\255\255\255\255\255\255\255\047\000\255\255\047\000\
    \047\000\047\000\047\000\047\000\047\000\047\000\047\000\047\000\
    \047\000\047\000\047\000\047\000\047\000\047\000\047\000\047\000\
    \047\000\047\000\047\000\047\000\047\000\047\000\047\000\047\000\
    \047\000\048\000\180\000\196\000\181\000\225\000\225\000\225\000\
    \225\000\225\000\225\000\225\000\225\000\048\000\048\000\048\000\
    \048\000\048\000\048\000\048\000\048\000\048\000\048\000\048\000\
    \255\255\048\000\255\255\255\255\255\255\255\255\048\000\048\000\
    \048\000\048\000\048\000\048\000\048\000\048\000\048\000\048\000\
    \048\000\048\000\048\000\048\000\048\000\048\000\048\000\048\000\
    \048\000\048\000\048\000\048\000\048\000\048\000\048\000\048\000\
    \255\255\255\255\255\255\255\255\048\000\255\255\048\000\048\000\
    \048\000\048\000\048\000\048\000\048\000\048\000\048\000\048\000\
    \048\000\048\000\048\000\048\000\048\000\048\000\048\000\048\000\
    \048\000\048\000\048\000\048\000\048\000\048\000\048\000\048\000\
    \049\000\199\000\204\000\182\000\255\255\185\000\255\255\255\255\
    \184\000\207\000\255\255\255\255\049\000\049\000\049\000\049\000\
    \049\000\049\000\049\000\049\000\049\000\049\000\049\000\255\255\
    \049\000\177\000\255\255\255\255\255\255\049\000\049\000\049\000\
    \049\000\049\000\049\000\049\000\049\000\049\000\049\000\049\000\
    \049\000\049\000\049\000\049\000\049\000\049\000\049\000\049\000\
    \049\000\049\000\049\000\049\000\049\000\049\000\049\000\255\255\
    \255\255\255\255\255\255\049\000\255\255\049\000\049\000\049\000\
    \049\000\049\000\049\000\049\000\049\000\049\000\049\000\049\000\
    \049\000\049\000\049\000\049\000\049\000\049\000\049\000\049\000\
    \049\000\049\000\049\000\049\000\049\000\049\000\049\000\050\000\
    \255\255\211\000\211\000\211\000\211\000\211\000\211\000\211\000\
    \211\000\211\000\211\000\050\000\050\000\050\000\050\000\050\000\
    \050\000\050\000\050\000\050\000\050\000\050\000\211\000\050\000\
    \252\000\252\000\252\000\252\000\050\000\050\000\050\000\050\000\
    \050\000\050\000\050\000\050\000\050\000\050\000\050\000\050\000\
    \050\000\050\000\050\000\050\000\050\000\050\000\050\000\050\000\
    \050\000\050\000\050\000\050\000\050\000\050\000\211\000\255\255\
    \252\000\252\000\050\000\255\255\050\000\050\000\050\000\050\000\
    \050\000\050\000\050\000\050\000\050\000\050\000\050\000\050\000\
    \050\000\050\000\050\000\050\000\050\000\050\000\050\000\050\000\
    \050\000\050\000\050\000\050\000\050\000\050\000\051\000\215\000\
    \215\000\215\000\215\000\215\000\215\000\215\000\215\000\215\000\
    \215\000\255\255\051\000\051\000\051\000\051\000\051\000\051\000\
    \051\000\051\000\051\000\051\000\051\000\255\255\051\000\255\255\
    \255\255\255\255\255\255\051\000\051\000\051\000\051\000\051\000\
    \051\000\051\000\051\000\051\000\051\000\051\000\051\000\051\000\
    \051\000\051\000\051\000\051\000\051\000\051\000\051\000\051\000\
    \051\000\051\000\051\000\051\000\051\000\255\255\255\255\255\255\
    \255\255\051\000\255\255\051\000\051\000\051\000\051\000\051\000\
    \051\000\051\000\051\000\051\000\051\000\051\000\051\000\051\000\
    \051\000\051\000\051\000\051\000\051\000\051\000\051\000\051\000\
    \051\000\051\000\051\000\051\000\051\000\052\000\216\000\216\000\
    \216\000\216\000\216\000\216\000\216\000\216\000\216\000\216\000\
    \255\255\052\000\052\000\052\000\052\000\052\000\052\000\052\000\
    \052\000\052\000\052\000\052\000\255\255\052\000\255\255\255\255\
    \255\255\255\255\052\000\052\000\052\000\052\000\052\000\052\000\
    \052\000\052\000\052\000\052\000\052\000\052\000\052\000\052\000\
    \052\000\052\000\052\000\052\000\052\000\052\000\052\000\052\000\
    \052\000\052\000\052\000\052\000\255\255\255\255\255\255\255\255\
    \052\000\255\255\052\000\052\000\052\000\052\000\052\000\052\000\
    \052\000\052\000\052\000\052\000\052\000\052\000\052\000\052\000\
    \052\000\052\000\052\000\052\000\052\000\052\000\052\000\052\000\
    \052\000\052\000\052\000\052\000\053\000\226\000\226\000\226\000\
    \226\000\226\000\226\000\226\000\226\000\255\255\252\000\255\255\
    \053\000\053\000\053\000\053\000\053\000\053\000\053\000\053\000\
    \053\000\053\000\053\000\255\255\053\000\255\255\255\255\255\255\
    \255\255\053\000\053\000\053\000\053\000\053\000\053\000\053\000\
    \053\000\053\000\053\000\053\000\053\000\053\000\053\000\053\000\
    \053\000\053\000\053\000\053\000\053\000\053\000\053\000\053\000\
    \053\000\053\000\053\000\255\255\255\255\255\255\255\255\053\000\
    \255\255\053\000\053\000\053\000\053\000\053\000\053\000\053\000\
    \053\000\053\000\053\000\053\000\053\000\053\000\053\000\053\000\
    \053\000\053\000\053\000\053\000\053\000\053\000\053\000\053\000\
    \053\000\053\000\053\000\054\000\236\000\236\000\236\000\236\000\
    \236\000\236\000\236\000\236\000\255\255\255\255\255\255\054\000\
    \054\000\054\000\054\000\054\000\054\000\054\000\054\000\054\000\
    \054\000\054\000\255\255\054\000\255\255\255\255\255\255\255\255\
    \054\000\054\000\054\000\054\000\054\000\054\000\054\000\054\000\
    \054\000\054\000\054\000\054\000\054\000\054\000\054\000\054\000\
    \054\000\054\000\054\000\054\000\054\000\054\000\054\000\054\000\
    \054\000\054\000\255\255\255\255\255\255\255\255\054\000\255\255\
    \054\000\054\000\054\000\054\000\054\000\054\000\054\000\054\000\
    \054\000\054\000\054\000\054\000\054\000\054\000\054\000\054\000\
    \054\000\054\000\054\000\054\000\054\000\054\000\054\000\054\000\
    \054\000\054\000\055\000\237\000\237\000\237\000\237\000\237\000\
    \237\000\237\000\237\000\255\255\255\255\255\255\055\000\055\000\
    \055\000\055\000\055\000\055\000\055\000\055\000\055\000\055\000\
    \055\000\255\255\055\000\255\255\255\255\255\255\255\255\055\000\
    \055\000\055\000\055\000\055\000\055\000\055\000\055\000\055\000\
    \055\000\055\000\055\000\055\000\055\000\055\000\055\000\055\000\
    \055\000\055\000\055\000\055\000\055\000\055\000\055\000\055\000\
    \055\000\241\000\255\255\230\000\255\255\055\000\255\255\055\000\
    \055\000\055\000\055\000\055\000\055\000\055\000\055\000\055\000\
    \055\000\055\000\055\000\055\000\055\000\055\000\055\000\055\000\
    \055\000\055\000\055\000\055\000\055\000\055\000\055\000\055\000\
    \055\000\056\000\247\000\247\000\247\000\247\000\247\000\247\000\
    \247\000\247\000\255\255\255\255\255\255\056\000\056\000\056\000\
    \056\000\056\000\056\000\056\000\056\000\056\000\056\000\056\000\
    \230\000\056\000\255\255\241\000\255\255\255\255\056\000\056\000\
    \056\000\056\000\056\000\056\000\056\000\056\000\056\000\056\000\
    \056\000\056\000\056\000\056\000\056\000\056\000\056\000\056\000\
    \056\000\056\000\056\000\056\000\056\000\056\000\056\000\056\000\
    \255\255\255\255\255\255\255\255\056\000\255\255\056\000\056\000\
    \056\000\056\000\056\000\056\000\056\000\056\000\056\000\056\000\
    \056\000\056\000\056\000\056\000\056\000\056\000\056\000\056\000\
    \056\000\056\000\056\000\056\000\056\000\056\000\056\000\056\000\
    \057\000\255\255\255\255\150\000\248\000\248\000\248\000\248\000\
    \248\000\248\000\248\000\248\000\057\000\057\000\057\000\057\000\
    \057\000\057\000\057\000\057\000\057\000\057\000\057\000\255\255\
    \057\000\255\255\150\000\255\255\255\255\057\000\057\000\057\000\
    \057\000\057\000\057\000\057\000\057\000\057\000\057\000\057\000\
    \057\000\057\000\057\000\057\000\057\000\057\000\057\000\057\000\
    \057\000\057\000\057\000\057\000\057\000\057\000\057\000\255\255\
    \255\255\255\255\255\255\057\000\255\255\057\000\057\000\057\000\
    \057\000\057\000\057\000\057\000\057\000\057\000\057\000\057\000\
    \057\000\057\000\057\000\057\000\057\000\057\000\057\000\057\000\
    \057\000\057\000\057\000\057\000\057\000\057\000\057\000\058\000\
    \255\255\255\255\172\000\255\255\255\255\255\255\150\000\150\000\
    \255\255\255\255\255\255\150\000\230\000\255\255\150\000\241\000\
    \255\255\255\255\150\000\255\255\255\255\255\255\058\000\150\000\
    \255\255\172\000\058\000\172\000\255\255\255\255\058\000\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\058\000\058\000\
    \058\000\058\000\058\000\058\000\058\000\058\000\058\000\058\000\
    \058\000\255\255\058\000\255\255\255\255\172\000\255\255\058\000\
    \058\000\058\000\058\000\058\000\058\000\058\000\058\000\058\000\
    \058\000\058\000\058\000\058\000\058\000\058\000\058\000\058\000\
    \058\000\058\000\058\000\058\000\058\000\058\000\058\000\058\000\
    \058\000\255\255\255\255\255\255\255\255\058\000\255\255\058\000\
    \058\000\058\000\058\000\058\000\058\000\058\000\058\000\058\000\
    \058\000\058\000\058\000\058\000\058\000\058\000\058\000\058\000\
    \058\000\058\000\058\000\058\000\058\000\058\000\058\000\058\000\
    \058\000\064\000\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\255\255\
    \255\255\255\255\255\255\064\000\255\255\255\255\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \255\255\255\255\255\255\255\255\064\000\255\255\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \064\000\064\000\064\000\064\000\064\000\064\000\064\000\064\000\
    \066\000\255\255\212\000\064\000\212\000\255\255\255\255\212\000\
    \212\000\212\000\212\000\212\000\212\000\212\000\212\000\212\000\
    \212\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\066\000\066\000\066\000\
    \066\000\066\000\066\000\066\000\066\000\066\000\066\000\066\000\
    \066\000\066\000\066\000\066\000\066\000\066\000\066\000\066\000\
    \066\000\066\000\066\000\066\000\066\000\066\000\066\000\255\255\
    \255\255\255\255\255\255\066\000\255\255\066\000\066\000\066\000\
    \066\000\066\000\066\000\066\000\066\000\066\000\066\000\066\000\
    \066\000\066\000\066\000\066\000\066\000\066\000\066\000\066\000\
    \066\000\066\000\066\000\066\000\066\000\066\000\066\000\067\000\
    \255\255\255\255\066\000\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\255\255\067\000\
    \255\255\255\255\255\255\255\255\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\255\255\255\255\
    \255\255\068\000\067\000\255\255\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\067\000\067\000\
    \067\000\067\000\067\000\067\000\067\000\067\000\068\000\068\000\
    \068\000\068\000\068\000\068\000\068\000\068\000\068\000\068\000\
    \068\000\068\000\068\000\068\000\068\000\068\000\068\000\068\000\
    \068\000\068\000\068\000\068\000\068\000\068\000\068\000\068\000\
    \255\255\255\255\255\255\255\255\068\000\255\255\068\000\068\000\
    \068\000\068\000\068\000\068\000\068\000\068\000\068\000\068\000\
    \068\000\068\000\068\000\068\000\068\000\068\000\068\000\068\000\
    \068\000\068\000\068\000\068\000\068\000\068\000\068\000\068\000\
    \069\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\255\255\
    \069\000\255\255\255\255\255\255\255\255\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\255\255\
    \255\255\255\255\070\000\069\000\255\255\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\069\000\
    \069\000\069\000\069\000\069\000\069\000\069\000\069\000\070\000\
    \070\000\070\000\070\000\070\000\070\000\070\000\070\000\070\000\
    \070\000\070\000\070\000\070\000\070\000\070\000\070\000\070\000\
    \070\000\070\000\070\000\070\000\070\000\070\000\070\000\070\000\
    \070\000\255\255\255\255\255\255\255\255\070\000\255\255\070\000\
    \070\000\070\000\070\000\070\000\070\000\070\000\070\000\070\000\
    \070\000\070\000\070\000\070\000\070\000\070\000\070\000\070\000\
    \070\000\070\000\070\000\070\000\070\000\070\000\070\000\070\000\
    \070\000\073\000\255\255\255\255\070\000\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\255\255\
    \255\255\255\255\255\255\073\000\255\255\255\255\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \255\255\255\255\255\255\255\255\073\000\255\255\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \073\000\073\000\073\000\073\000\073\000\073\000\073\000\073\000\
    \076\000\255\255\213\000\073\000\213\000\213\000\213\000\213\000\
    \213\000\213\000\213\000\213\000\213\000\213\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\213\000\255\255\255\255\255\255\076\000\076\000\076\000\
    \076\000\076\000\076\000\076\000\076\000\076\000\076\000\076\000\
    \076\000\076\000\076\000\076\000\076\000\076\000\076\000\076\000\
    \076\000\076\000\076\000\076\000\076\000\076\000\076\000\255\255\
    \255\255\213\000\255\255\076\000\255\255\076\000\076\000\076\000\
    \076\000\076\000\076\000\076\000\076\000\076\000\076\000\076\000\
    \076\000\076\000\076\000\076\000\076\000\076\000\076\000\076\000\
    \076\000\076\000\076\000\076\000\076\000\076\000\076\000\077\000\
    \255\255\255\255\076\000\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\255\255\255\255\255\255\
    \255\255\077\000\255\255\255\255\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\255\255\255\255\
    \255\255\255\255\077\000\255\255\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\077\000\077\000\
    \077\000\077\000\077\000\077\000\077\000\077\000\079\000\255\255\
    \255\255\077\000\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\079\000\079\000\079\000\079\000\079\000\
    \079\000\079\000\079\000\079\000\079\000\079\000\079\000\079\000\
    \079\000\079\000\079\000\079\000\079\000\079\000\079\000\079\000\
    \079\000\079\000\079\000\079\000\079\000\255\255\255\255\255\255\
    \255\255\079\000\255\255\079\000\079\000\079\000\079\000\079\000\
    \079\000\079\000\079\000\079\000\079\000\079\000\079\000\079\000\
    \079\000\079\000\079\000\079\000\079\000\079\000\079\000\079\000\
    \079\000\079\000\079\000\079\000\079\000\080\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\255\255\080\000\255\255\255\255\
    \255\255\255\255\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\255\255\255\255\255\255\081\000\
    \080\000\255\255\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\080\000\080\000\080\000\080\000\
    \080\000\080\000\080\000\080\000\081\000\081\000\081\000\081\000\
    \081\000\081\000\081\000\081\000\081\000\081\000\081\000\081\000\
    \081\000\081\000\081\000\081\000\081\000\081\000\081\000\081\000\
    \081\000\081\000\081\000\081\000\081\000\081\000\255\255\255\255\
    \255\255\255\255\081\000\255\255\081\000\081\000\081\000\081\000\
    \081\000\081\000\081\000\081\000\081\000\081\000\081\000\081\000\
    \081\000\081\000\081\000\081\000\081\000\081\000\081\000\081\000\
    \081\000\081\000\081\000\081\000\081\000\081\000\082\000\255\255\
    \255\255\081\000\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\255\255\255\255\255\255\255\255\
    \082\000\255\255\255\255\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\255\255\255\255\255\255\
    \255\255\082\000\255\255\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\082\000\082\000\082\000\
    \082\000\082\000\082\000\082\000\082\000\089\000\255\255\255\255\
    \082\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\089\000\089\000\089\000\089\000\089\000\089\000\089\000\
    \089\000\089\000\089\000\089\000\255\255\089\000\255\255\255\255\
    \255\255\255\255\089\000\089\000\089\000\089\000\089\000\089\000\
    \089\000\089\000\089\000\089\000\089\000\089\000\089\000\089\000\
    \089\000\089\000\089\000\089\000\089\000\089\000\089\000\089\000\
    \089\000\089\000\089\000\089\000\255\255\255\255\255\255\255\255\
    \089\000\255\255\089\000\089\000\089\000\089\000\089\000\089\000\
    \089\000\089\000\089\000\089\000\089\000\089\000\089\000\089\000\
    \089\000\089\000\089\000\089\000\089\000\089\000\089\000\089\000\
    \089\000\089\000\089\000\089\000\090\000\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \090\000\090\000\090\000\090\000\090\000\090\000\090\000\090\000\
    \090\000\090\000\090\000\255\255\090\000\255\255\255\255\255\255\
    \255\255\090\000\090\000\090\000\090\000\090\000\090\000\090\000\
    \090\000\090\000\090\000\090\000\090\000\090\000\090\000\090\000\
    \090\000\090\000\090\000\090\000\090\000\090\000\090\000\090\000\
    \090\000\090\000\090\000\255\255\255\255\255\255\255\255\090\000\
    \255\255\090\000\090\000\090\000\090\000\090\000\090\000\090\000\
    \090\000\090\000\090\000\090\000\090\000\090\000\090\000\090\000\
    \090\000\090\000\090\000\090\000\090\000\090\000\090\000\090\000\
    \090\000\090\000\090\000\091\000\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\091\000\
    \091\000\091\000\091\000\091\000\091\000\091\000\091\000\091\000\
    \091\000\091\000\255\255\091\000\255\255\255\255\255\255\255\255\
    \091\000\091\000\091\000\091\000\091\000\091\000\091\000\091\000\
    \091\000\091\000\091\000\091\000\091\000\091\000\091\000\091\000\
    \091\000\091\000\091\000\091\000\091\000\091\000\091\000\091\000\
    \091\000\091\000\255\255\255\255\255\255\255\255\091\000\255\255\
    \091\000\091\000\091\000\091\000\091\000\091\000\091\000\091\000\
    \091\000\091\000\091\000\091\000\091\000\091\000\091\000\091\000\
    \091\000\091\000\091\000\091\000\091\000\091\000\091\000\091\000\
    \091\000\091\000\092\000\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\092\000\092\000\
    \092\000\092\000\092\000\092\000\092\000\092\000\092\000\092\000\
    \092\000\255\255\092\000\255\255\255\255\255\255\255\255\092\000\
    \092\000\092\000\092\000\092\000\092\000\092\000\092\000\092\000\
    \092\000\092\000\092\000\092\000\092\000\092\000\092\000\092\000\
    \092\000\092\000\092\000\092\000\092\000\092\000\092\000\092\000\
    \092\000\255\255\255\255\255\255\255\255\092\000\255\255\092\000\
    \092\000\092\000\092\000\092\000\092\000\092\000\092\000\092\000\
    \092\000\092\000\092\000\092\000\092\000\092\000\092\000\092\000\
    \092\000\092\000\092\000\092\000\092\000\092\000\092\000\092\000\
    \092\000\093\000\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\093\000\093\000\093\000\
    \093\000\093\000\093\000\093\000\093\000\093\000\093\000\093\000\
    \255\255\093\000\255\255\255\255\255\255\255\255\093\000\093\000\
    \093\000\093\000\093\000\093\000\093\000\093\000\093\000\093\000\
    \093\000\093\000\093\000\093\000\093\000\093\000\093\000\093\000\
    \093\000\093\000\093\000\093\000\093\000\093\000\093\000\093\000\
    \255\255\255\255\255\255\134\000\093\000\255\255\093\000\093\000\
    \093\000\093\000\093\000\093\000\093\000\093\000\093\000\093\000\
    \093\000\093\000\093\000\093\000\093\000\093\000\093\000\093\000\
    \093\000\093\000\093\000\093\000\093\000\093\000\093\000\093\000\
    \134\000\134\000\134\000\134\000\134\000\134\000\134\000\134\000\
    \134\000\134\000\134\000\134\000\134\000\134\000\134\000\134\000\
    \134\000\134\000\134\000\134\000\134\000\134\000\134\000\134\000\
    \134\000\134\000\255\255\255\255\255\255\255\255\134\000\255\255\
    \134\000\134\000\134\000\134\000\134\000\134\000\134\000\134\000\
    \134\000\134\000\134\000\134\000\134\000\134\000\134\000\134\000\
    \134\000\134\000\134\000\134\000\134\000\134\000\134\000\134\000\
    \134\000\134\000\135\000\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\255\255\135\000\255\255\255\255\255\255\255\255\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\255\255\255\255\255\255\137\000\135\000\255\255\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\135\000\135\000\135\000\135\000\135\000\135\000\135\000\
    \135\000\137\000\137\000\137\000\137\000\137\000\137\000\137\000\
    \137\000\137\000\137\000\137\000\137\000\137\000\137\000\137\000\
    \137\000\137\000\137\000\137\000\137\000\137\000\137\000\137\000\
    \137\000\137\000\137\000\255\255\255\255\255\255\255\255\137\000\
    \255\255\137\000\137\000\137\000\137\000\137\000\137\000\137\000\
    \137\000\137\000\137\000\137\000\137\000\137\000\137\000\137\000\
    \137\000\137\000\137\000\137\000\137\000\137\000\137\000\137\000\
    \137\000\137\000\137\000\138\000\255\255\255\255\137\000\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\255\255\255\255\255\255\255\255\138\000\255\255\255\255\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\255\255\255\255\255\255\255\255\138\000\255\255\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\138\000\138\000\138\000\138\000\138\000\138\000\
    \138\000\138\000\140\000\255\255\255\255\138\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\140\000\
    \140\000\140\000\140\000\140\000\140\000\140\000\140\000\140\000\
    \140\000\140\000\140\000\140\000\140\000\140\000\140\000\140\000\
    \140\000\140\000\140\000\140\000\140\000\140\000\140\000\140\000\
    \140\000\255\255\255\255\255\255\255\255\140\000\255\255\140\000\
    \140\000\140\000\140\000\140\000\140\000\140\000\140\000\140\000\
    \140\000\140\000\140\000\140\000\140\000\140\000\140\000\140\000\
    \140\000\140\000\140\000\140\000\140\000\140\000\140\000\140\000\
    \140\000\141\000\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \255\255\141\000\255\255\255\255\255\255\255\255\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \255\255\255\255\255\255\142\000\141\000\255\255\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \141\000\141\000\141\000\141\000\141\000\141\000\141\000\141\000\
    \142\000\142\000\142\000\142\000\142\000\142\000\142\000\142\000\
    \142\000\142\000\142\000\142\000\142\000\142\000\142\000\142\000\
    \142\000\142\000\142\000\142\000\142\000\142\000\142\000\142\000\
    \142\000\142\000\255\255\255\255\255\255\255\255\142\000\255\255\
    \142\000\142\000\142\000\142\000\142\000\142\000\142\000\142\000\
    \142\000\142\000\142\000\142\000\142\000\142\000\142\000\142\000\
    \142\000\142\000\142\000\142\000\142\000\142\000\142\000\142\000\
    \142\000\142\000\143\000\166\000\255\255\142\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \255\255\255\255\255\255\255\255\143\000\255\255\255\255\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\255\255\255\255\255\255\255\255\143\000\255\255\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\143\000\143\000\143\000\143\000\143\000\143\000\143\000\
    \143\000\156\000\208\000\255\255\143\000\166\000\255\255\255\255\
    \255\255\255\255\255\255\208\000\255\255\255\255\255\255\166\000\
    \222\000\222\000\222\000\222\000\222\000\222\000\222\000\222\000\
    \156\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\208\000\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\208\000\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\156\000\156\000\156\000\156\000\156\000\156\000\156\000\
    \156\000\156\000\156\000\156\000\156\000\156\000\156\000\156\000\
    \156\000\156\000\156\000\156\000\156\000\156\000\156\000\156\000\
    \156\000\156\000\156\000\255\255\255\255\255\255\255\255\156\000\
    \222\000\156\000\156\000\156\000\156\000\156\000\156\000\156\000\
    \156\000\156\000\156\000\156\000\156\000\156\000\156\000\156\000\
    \156\000\156\000\156\000\156\000\156\000\156\000\156\000\156\000\
    \156\000\156\000\156\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\255\255\255\255\
    \255\255\166\000\157\000\255\255\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\157\000\157\000\
    \157\000\157\000\157\000\157\000\157\000\157\000\163\000\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\232\000\232\000\232\000\232\000\232\000\232\000\
    \232\000\232\000\255\255\255\255\255\255\163\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \222\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\243\000\243\000\243\000\243\000\243\000\
    \243\000\243\000\243\000\255\255\255\255\255\255\163\000\163\000\
    \163\000\163\000\163\000\163\000\163\000\163\000\163\000\163\000\
    \163\000\163\000\163\000\163\000\163\000\163\000\163\000\163\000\
    \163\000\163\000\163\000\163\000\163\000\163\000\163\000\163\000\
    \255\255\255\255\232\000\255\255\163\000\255\255\163\000\163\000\
    \163\000\163\000\163\000\163\000\163\000\163\000\163\000\163\000\
    \163\000\163\000\163\000\163\000\163\000\163\000\163\000\163\000\
    \163\000\163\000\163\000\163\000\163\000\163\000\163\000\163\000\
    \164\000\255\255\255\255\243\000\255\255\255\255\255\255\255\255\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\255\255\255\255\255\255\255\255\164\000\
    \255\255\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\164\000\164\000\164\000\164\000\164\000\
    \164\000\164\000\164\000\210\000\210\000\210\000\210\000\210\000\
    \210\000\210\000\210\000\210\000\210\000\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\210\000\210\000\210\000\210\000\
    \210\000\210\000\232\000\255\255\214\000\255\255\214\000\214\000\
    \214\000\214\000\214\000\214\000\214\000\214\000\214\000\214\000\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\214\000\210\000\210\000\210\000\210\000\
    \210\000\210\000\214\000\243\000\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\214\000\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\214\000\255\255\255\255\255\255\255\255\
    \255\255\255\255\214\000\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\214\000\217\000\217\000\217\000\217\000\
    \217\000\217\000\217\000\217\000\217\000\217\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\217\000\217\000\217\000\
    \217\000\217\000\217\000\255\255\255\255\255\255\255\255\255\255\
    \217\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\217\000\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\217\000\217\000\217\000\
    \217\000\217\000\217\000\255\255\255\255\255\255\255\255\255\255\
    \217\000\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\217\000\224\000\224\000\224\000\224\000\224\000\224\000\
    \224\000\224\000\224\000\224\000\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\224\000\224\000\224\000\224\000\224\000\
    \224\000\228\000\228\000\228\000\228\000\228\000\228\000\228\000\
    \228\000\228\000\228\000\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\228\000\228\000\228\000\228\000\228\000\228\000\
    \255\255\255\255\255\255\224\000\224\000\224\000\224\000\224\000\
    \224\000\255\255\255\255\255\255\255\255\255\255\255\255\235\000\
    \235\000\235\000\235\000\235\000\235\000\235\000\235\000\235\000\
    \235\000\255\255\228\000\228\000\228\000\228\000\228\000\228\000\
    \235\000\235\000\235\000\235\000\235\000\235\000\239\000\239\000\
    \239\000\239\000\239\000\239\000\239\000\239\000\239\000\239\000\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\239\000\
    \239\000\239\000\239\000\239\000\239\000\255\255\255\255\255\255\
    \235\000\235\000\235\000\235\000\235\000\235\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\246\000\246\000\246\000\246\000\
    \246\000\246\000\246\000\246\000\246\000\246\000\255\255\239\000\
    \239\000\239\000\239\000\239\000\239\000\246\000\246\000\246\000\
    \246\000\246\000\246\000\250\000\250\000\250\000\250\000\250\000\
    \250\000\250\000\250\000\250\000\250\000\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\250\000\250\000\250\000\250\000\
    \250\000\250\000\255\255\255\255\255\255\246\000\246\000\246\000\
    \246\000\246\000\246\000\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\250\000\250\000\250\000\250\000\
    \250\000\250\000\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255";
  Lexing.lex_base_code = 
   "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\002\000\003\000\000\000\000\000\000\000\
    \000\000\000\000\004\000\005\000\000\000\021\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000";
  Lexing.lex_backtrk_code = 
   "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\004\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\010\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\018\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000";
  Lexing.lex_default_code = 
   "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000";
  Lexing.lex_trans_code = 
   "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\001\000\001\000\007\000\007\000\013\000\013\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \001\000\001\000\007\000\007\000\013\000\013\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\
    \000\000\000\000\000\000\000\000\000\000\000\000";
  Lexing.lex_check_code = 
   "\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\000\000\040\000\155\000\156\000\162\000\163\000\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \000\000\040\000\155\000\156\000\162\000\163\000\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\
    \255\255\255\255\255\255\255\255\255\255\255\255";
  Lexing.lex_code = 
   "\255\001\255\255\000\001\255\002\255\255\000\002\255\004\255\003\
    \255\255\000\003\255\000\004\255";
}

let rec token lexbuf =
  lexbuf.Lexing.lex_mem <- Array.create 5 (-1) ; (* L=1 [1] <- p ;  *)
  lexbuf.Lexing.lex_mem.(1) <- lexbuf.Lexing.lex_curr_pos ;
  __ocaml_lex_token_rec lexbuf 0
and __ocaml_lex_token_rec lexbuf __ocaml_lex_state =
  match Lexing.new_engine __ocaml_lex_tables __ocaml_lex_state lexbuf with
      | 0 ->
# 508 "lexer_cocci.mll"
    ( let cls = !current_line_started in

      if not cls
      then
	begin
	  match !current_line_type with
	    (D.PLUS,_,_) | (D.PLUSPLUS,_,_) ->
	      let info = get_current_line_type lexbuf in
	      reset_line lexbuf;
	      TPragma (Ast.Noindent "", info)
	  | _ -> reset_line lexbuf; token lexbuf
	end
      else (reset_line lexbuf; token lexbuf) )
# 2005 "lexer_cocci.ml"

  | 1 ->
# 522 "lexer_cocci.mll"
                   ( start_line false; token lexbuf )
# 2010 "lexer_cocci.ml"

  | 2 ->
let
# 524 "lexer_cocci.mll"
                                       after
# 2016 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_mem.(0) lexbuf.Lexing.lex_curr_pos in
# 524 "lexer_cocci.mll"
                                              (
    match !current_line_type with
      (D.PLUS,_,_) | (D.PLUSPLUS,_,_) ->
	let str =
	  if !current_line_started
	  then (tok lexbuf)
	  else after in
	start_line true;
	TPragma (Ast.Indent str, get_current_line_type lexbuf)
    | _ -> start_line false; token lexbuf )
# 2029 "lexer_cocci.ml"

  | 3 ->
# 536 "lexer_cocci.mll"
   ( match !current_line_type with
      (D.PLUS,_,_) | (D.PLUSPLUS,_,_) ->
	start_line true;
	TPragma (Ast.Space (tok lexbuf), get_current_line_type lexbuf)
    | _ -> failwith "attributes only allowedin + code" )
# 2038 "lexer_cocci.ml"

  | 4 ->
# 542 "lexer_cocci.mll"
         ( start_line true; TArobArob )
# 2043 "lexer_cocci.ml"

  | 5 ->
# 543 "lexer_cocci.mll"
         ( pass_zero();
	   if !Data.in_rule_name or not !current_line_started
	   then (start_line true; TArob)
	   else (check_minus_context_linetype "@";
		 TPArob (get_current_line_type lexbuf)) )
# 2052 "lexer_cocci.ml"

  | 6 ->
# 549 "lexer_cocci.mll"
          ( start_line true; TTildeEq (get_current_line_type lexbuf) )
# 2057 "lexer_cocci.ml"

  | 7 ->
# 550 "lexer_cocci.mll"
         ( start_line true; TTildeExclEq (get_current_line_type lexbuf) )
# 2062 "lexer_cocci.ml"

  | 8 ->
# 552 "lexer_cocci.mll"
      ( start_line true; check_minus_context_linetype (tok lexbuf);
	TWhen (get_current_line_type lexbuf) )
# 2068 "lexer_cocci.ml"

  | 9 ->
# 556 "lexer_cocci.mll"
      ( start_line true; check_minus_context_linetype (tok lexbuf);
	TEllipsis (get_current_line_type lexbuf) )
# 2074 "lexer_cocci.ml"

  | 10 ->
# 567 "lexer_cocci.mll"
           ( start_line true; check_context_linetype (tok lexbuf);
	     TOEllipsis (get_current_line_type lexbuf) )
# 2080 "lexer_cocci.ml"

  | 11 ->
# 569 "lexer_cocci.mll"
           ( start_line true; check_context_linetype (tok lexbuf);
	     TCEllipsis (get_current_line_type lexbuf) )
# 2086 "lexer_cocci.ml"

  | 12 ->
# 571 "lexer_cocci.mll"
            ( start_line true; check_minus_context_linetype (tok lexbuf);
	     TPOEllipsis (get_current_line_type lexbuf) )
# 2092 "lexer_cocci.ml"

  | 13 ->
# 573 "lexer_cocci.mll"
            ( start_line true; check_minus_context_linetype (tok lexbuf);
	     TPCEllipsis (get_current_line_type lexbuf) )
# 2098 "lexer_cocci.ml"

  | 14 ->
# 586 "lexer_cocci.mll"
        ( pass_zero();
	  if !current_line_started
	  then (start_line true; TMinus (get_current_line_type lexbuf))
          else (patch_or_match PATCH;
		add_current_line_type D.MINUS; token lexbuf) )
# 2107 "lexer_cocci.ml"

  | 15 ->
# 591 "lexer_cocci.mll"
        ( pass_zero();
	  if !current_line_started
	  then (start_line true; TPlus (get_current_line_type lexbuf))
          else if !Data.in_meta
	  then TPlus0
          else (patch_or_match PATCH;
		add_current_line_type D.PLUS; token lexbuf) )
# 2118 "lexer_cocci.ml"

  | 16 ->
# 598 "lexer_cocci.mll"
        ( pass_zero();
	  if !current_line_started
	  then (start_line true; TWhy (get_current_line_type lexbuf))
          else if !Data.in_meta
	  then TWhy0
          else (add_current_line_type D.OPT; token lexbuf) )
# 2128 "lexer_cocci.ml"

  | 17 ->
# 604 "lexer_cocci.mll"
        ( pass_zero();
	  if !current_line_started
	  then (start_line true; TBang (get_current_line_type lexbuf))
          else if !Data.in_meta
	  then TBang0
          else (add_current_line_type D.UNIQUE; token lexbuf) )
# 2138 "lexer_cocci.ml"

  | 18 ->
# 610 "lexer_cocci.mll"
        ( if !Data.in_meta or not !col_zero
	  then (start_line true; TOPar (get_current_line_type lexbuf))
          else
            (start_line true; check_context_linetype (tok lexbuf);
	     TOPar0 (get_current_line_type lexbuf)))
# 2147 "lexer_cocci.ml"

  | 19 ->
# 615 "lexer_cocci.mll"
          ( start_line true;
	    TOPar0 (contextify(get_current_line_type lexbuf)) )
# 2153 "lexer_cocci.ml"

  | 20 ->
# 617 "lexer_cocci.mll"
        ( if not (!col_zero)
	  then (start_line true; TOr(get_current_line_type lexbuf))
          else (start_line true;
		check_context_linetype (tok lexbuf);
		TMid0 (get_current_line_type lexbuf)))
# 2162 "lexer_cocci.ml"

  | 21 ->
# 622 "lexer_cocci.mll"
          ( start_line true;
	    TMid0 (contextify(get_current_line_type lexbuf)) )
# 2168 "lexer_cocci.ml"

  | 22 ->
# 624 "lexer_cocci.mll"
        ( if not !col_zero
	  then (start_line true; TCPar (get_current_line_type lexbuf))
          else
            (start_line true; check_context_linetype (tok lexbuf);
	     TCPar0 (get_current_line_type lexbuf)))
# 2177 "lexer_cocci.ml"

  | 23 ->
# 629 "lexer_cocci.mll"
          ( start_line true;
	    TCPar0 (contextify(get_current_line_type lexbuf)) )
# 2183 "lexer_cocci.ml"

  | 24 ->
# 632 "lexer_cocci.mll"
        ( start_line true; TOCro (get_current_line_type lexbuf)   )
# 2188 "lexer_cocci.ml"

  | 25 ->
# 633 "lexer_cocci.mll"
        ( start_line true; TCCro (get_current_line_type lexbuf)   )
# 2193 "lexer_cocci.ml"

  | 26 ->
# 634 "lexer_cocci.mll"
        ( start_line true; TOBrace (get_current_line_type lexbuf) )
# 2198 "lexer_cocci.ml"

  | 27 ->
# 635 "lexer_cocci.mll"
        ( start_line true; TCBrace (get_current_line_type lexbuf) )
# 2203 "lexer_cocci.ml"

  | 28 ->
# 637 "lexer_cocci.mll"
                   ( start_line true; TPtrOp (get_current_line_type lexbuf)  )
# 2208 "lexer_cocci.ml"

  | 29 ->
# 638 "lexer_cocci.mll"
                   ( start_line true; TDot (get_current_line_type lexbuf)    )
# 2213 "lexer_cocci.ml"

  | 30 ->
# 639 "lexer_cocci.mll"
                   ( start_line true; TComma (get_current_line_type lexbuf)  )
# 2218 "lexer_cocci.ml"

  | 31 ->
# 640 "lexer_cocci.mll"
                   ( start_line true;
		     if !Data.in_meta
		     then TMPtVirg (* works better with tokens_all *)
		     else TPtVirg (get_current_line_type lexbuf) )
# 2226 "lexer_cocci.ml"

  | 32 ->
# 646 "lexer_cocci.mll"
                   ( pass_zero();
		     if !current_line_started
		     then
		       (start_line true; TMul (get_current_line_type lexbuf))
		     else
		       (patch_or_match MATCH;
			add_current_line_type D.MINUS; token lexbuf) )
# 2237 "lexer_cocci.ml"

  | 33 ->
# 653 "lexer_cocci.mll"
                   ( start_line true;
		     TDmOp (Ast.Div,get_current_line_type lexbuf) )
# 2243 "lexer_cocci.ml"

  | 34 ->
# 655 "lexer_cocci.mll"
                   ( start_line true;
		     TDmOp (Ast.Mod,get_current_line_type lexbuf) )
# 2249 "lexer_cocci.ml"

  | 35 ->
# 657 "lexer_cocci.mll"
                   ( start_line true;  TTilde (get_current_line_type lexbuf) )
# 2254 "lexer_cocci.ml"

  | 36 ->
# 659 "lexer_cocci.mll"
                   ( pass_zero();
 		     if !current_line_started
 		     then
 		       (start_line true; TInc (get_current_line_type lexbuf))
 		     else (patch_or_match PATCH;
 			   add_current_line_type D.PLUSPLUS; token lexbuf) )
# 2264 "lexer_cocci.ml"

  | 37 ->
# 665 "lexer_cocci.mll"
                   ( start_line true;  TDec (get_current_line_type lexbuf) )
# 2269 "lexer_cocci.ml"

  | 38 ->
# 667 "lexer_cocci.mll"
                   ( start_line true; TEq (get_current_line_type lexbuf) )
# 2274 "lexer_cocci.ml"

  | 39 ->
# 669 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.Minus lexbuf )
# 2279 "lexer_cocci.ml"

  | 40 ->
# 670 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.Plus lexbuf )
# 2284 "lexer_cocci.ml"

  | 41 ->
# 672 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.Mul lexbuf )
# 2289 "lexer_cocci.ml"

  | 42 ->
# 673 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.Div lexbuf )
# 2294 "lexer_cocci.ml"

  | 43 ->
# 674 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.Mod lexbuf )
# 2299 "lexer_cocci.ml"

  | 44 ->
# 676 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.And lexbuf )
# 2304 "lexer_cocci.ml"

  | 45 ->
# 677 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.Or lexbuf )
# 2309 "lexer_cocci.ml"

  | 46 ->
# 678 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.Xor lexbuf )
# 2314 "lexer_cocci.ml"

  | 47 ->
# 680 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.DecLeft lexbuf )
# 2319 "lexer_cocci.ml"

  | 48 ->
# 681 "lexer_cocci.mll"
                   ( start_line true; mkassign Ast.DecRight lexbuf )
# 2324 "lexer_cocci.ml"

  | 49 ->
# 683 "lexer_cocci.mll"
                   ( start_line true; TDotDot (get_current_line_type lexbuf) )
# 2329 "lexer_cocci.ml"

  | 50 ->
# 685 "lexer_cocci.mll"
                   ( start_line true; TEqEq    (get_current_line_type lexbuf) )
# 2334 "lexer_cocci.ml"

  | 51 ->
# 686 "lexer_cocci.mll"
                   ( start_line true; TNotEq   (get_current_line_type lexbuf) )
# 2339 "lexer_cocci.ml"

  | 52 ->
# 687 "lexer_cocci.mll"
                   ( start_line true;
		     TLogOp(Ast.SupEq,get_current_line_type lexbuf) )
# 2345 "lexer_cocci.ml"

  | 53 ->
# 689 "lexer_cocci.mll"
                   ( start_line true;
		     if !Data.in_meta
		     then TSub(get_current_line_type lexbuf)
		     else TLogOp(Ast.InfEq,get_current_line_type lexbuf) )
# 2353 "lexer_cocci.ml"

  | 54 ->
# 693 "lexer_cocci.mll"
                   ( start_line true;
		     TLogOp(Ast.Inf,get_current_line_type lexbuf) )
# 2359 "lexer_cocci.ml"

  | 55 ->
# 695 "lexer_cocci.mll"
                   ( start_line true;
		     TLogOp(Ast.Sup,get_current_line_type lexbuf) )
# 2365 "lexer_cocci.ml"

  | 56 ->
# 698 "lexer_cocci.mll"
                   ( start_line true; TAndLog (get_current_line_type lexbuf) )
# 2370 "lexer_cocci.ml"

  | 57 ->
# 699 "lexer_cocci.mll"
                   ( start_line true; TOrLog  (get_current_line_type lexbuf) )
# 2375 "lexer_cocci.ml"

  | 58 ->
# 701 "lexer_cocci.mll"
                   ( start_line true;
		     TShROp(Ast.DecRight,get_current_line_type lexbuf) )
# 2381 "lexer_cocci.ml"

  | 59 ->
# 703 "lexer_cocci.mll"
                   ( start_line true;
		     TShLOp(Ast.DecLeft,get_current_line_type lexbuf) )
# 2387 "lexer_cocci.ml"

  | 60 ->
# 706 "lexer_cocci.mll"
                   ( start_line true; TAnd    (get_current_line_type lexbuf) )
# 2392 "lexer_cocci.ml"

  | 61 ->
# 707 "lexer_cocci.mll"
                   ( start_line true; TXor(get_current_line_type lexbuf) )
# 2397 "lexer_cocci.ml"

  | 62 ->
# 709 "lexer_cocci.mll"
                    ( start_line true; TCppConcatOp )
# 2402 "lexer_cocci.ml"

  | 63 ->
let
# 710 "lexer_cocci.mll"
                                                  def
# 2408 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_mem.(0)
and
# 711 "lexer_cocci.mll"
                                   ident
# 2413 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_mem.(0) lexbuf.Lexing.lex_curr_pos in
# 712 "lexer_cocci.mll"
      ( start_line true;
	let (arity,line,lline,offset,col,strbef,straft,pos) as lt =
	  get_current_line_type lexbuf in
	let off = String.length def in
	(* -1 in the code below because the ident is not at the line start *)
	TUndef
	  (lt,
	   check_var ident
	     (arity,line,lline,offset+off,col+off,[],[],[])) )
# 2425 "lexer_cocci.ml"

  | 64 ->
let
# 721 "lexer_cocci.mll"
                                                   def
# 2431 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_mem.(0)
and
# 722 "lexer_cocci.mll"
                                   ident
# 2436 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_mem.(0) lexbuf.Lexing.lex_curr_pos in
# 723 "lexer_cocci.mll"
      ( start_line true;
	let (arity,line,lline,offset,col,strbef,straft,pos) as lt =
	  get_current_line_type lexbuf in
	let off = String.length def in
	(* -1 in the code below because the ident is not at the line start *)
	TDefine
	  (lt,
	   check_var ident
	     (arity,line,lline,offset+off,col+off,[],[],[])) )
# 2448 "lexer_cocci.ml"

  | 65 ->
let
# 732 "lexer_cocci.mll"
                                                   def
# 2454 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_mem.(0)
and
# 733 "lexer_cocci.mll"
                                    ident
# 2459 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_mem.(0) (lexbuf.Lexing.lex_curr_pos + -1) in
# 735 "lexer_cocci.mll"
      ( start_line true;
	let (arity,line,lline,offset,col,strbef,straft,pos) as lt =
	  get_current_line_type lexbuf in
	let off = String.length def in
	TDefineParam
        (lt,
	 check_var ident
	   (* why pos here but not above? *)
	   (arity,line,lline,offset+off,col+off,strbef,straft,pos),
	 offset + off + (String.length ident),
	 col + off + (String.length ident)) )
# 2473 "lexer_cocci.ml"

  | 66 ->
# 747 "lexer_cocci.mll"
      ( TIncludeL
	  (let str = tok lexbuf in
	  let start = String.index str '\"' in
	  let finish = String.rindex str '\"' in
	  start_line true;
	  (process_include start finish str,get_current_line_type lexbuf)) )
# 2483 "lexer_cocci.ml"

  | 67 ->
# 754 "lexer_cocci.mll"
      ( TIncludeNL
	  (let str = tok lexbuf in
	  let start = String.index str '<' in
	  let finish = String.rindex str '>' in
	  start_line true;
	  (process_include start finish str,get_current_line_type lexbuf)) )
# 2493 "lexer_cocci.ml"

  | 68 ->
# 769 "lexer_cocci.mll"
      ( start_line true; check_plus_linetype (tok lexbuf);
	TPragma (Ast.Noindent(tok lexbuf), get_current_line_type lexbuf) )
# 2499 "lexer_cocci.ml"

  | 69 ->
# 772 "lexer_cocci.mll"
      (
       match !current_line_type with
        (D.PLUS,_,_) | (D.PLUSPLUS,_,_) ->
        start_line true;
	(* second argument to TPragma is not quite right, because
	   it represents only the first token of the comment, but that
	   should be good enough *)
	TPragma (Ast.Indent("/*"^(comment check_comment lexbuf)),
		 get_current_line_type lexbuf)
      |	_ -> let _ = comment (fun _ -> ()) lexbuf in token lexbuf )
# 2513 "lexer_cocci.ml"

  | 70 ->
# 783 "lexer_cocci.mll"
      ( (if !current_line_started
      then lexerr "--- must be at the beginning of the line" "");
	start_line true;
	TMinusFile
	  (let str = tok lexbuf in
	  (drop_spaces(String.sub str 3 (String.length str - 3)),
	   (get_current_line_type lexbuf))) )
# 2524 "lexer_cocci.ml"

  | 71 ->
# 791 "lexer_cocci.mll"
      ( (if !current_line_started
      then lexerr "+++ must be at the beginning of the line" "");
	start_line true;
	TPlusFile
	  (let str = tok lexbuf in
	  (drop_spaces(String.sub str 3 (String.length str - 3)),
	   (get_current_line_type lexbuf))) )
# 2535 "lexer_cocci.ml"

  | 72 ->
# 800 "lexer_cocci.mll"
      ( start_line true; id_tokens lexbuf )
# 2540 "lexer_cocci.ml"

  | 73 ->
# 804 "lexer_cocci.mll"
      ( start_line true; id_tokens lexbuf )
# 2545 "lexer_cocci.ml"

  | 74 ->
# 811 "lexer_cocci.mll"
      ( 
	start_line true; 
	if not !Flag.c_plus_plus
	then Common.pr2_once "< and > not allowed in C identifiers, try -c++ option";
	id_tokens lexbuf 
      )
# 2555 "lexer_cocci.ml"

  | 75 ->
# 820 "lexer_cocci.mll"
      ( 
	start_line true; 
	if not !Flag.c_plus_plus
	then Common.pr2_once "< and > not allowed in C identifiers, try -c++ option";
	id_tokens lexbuf 
      )
# 2565 "lexer_cocci.ml"

  | 76 ->
# 834 "lexer_cocci.mll"
      ( 
	start_line true; 
	if not !Flag.c_plus_plus
	then Common.pr2_once "~ and :: not allowed in C identifiers, try -c++ option";
	id_tokens lexbuf 
      )
# 2575 "lexer_cocci.ml"

  | 77 ->
# 845 "lexer_cocci.mll"
      ( 
	start_line true; 
	if not !Flag.c_plus_plus
	then Common.pr2_once "~ and :: not allowed in C identifiers, try -c++ option";
	id_tokens lexbuf 
      )
# 2585 "lexer_cocci.ml"

  | 78 ->
# 854 "lexer_cocci.mll"
        ( start_line true;
	  TChar(char lexbuf,get_current_line_type lexbuf) )
# 2591 "lexer_cocci.ml"

  | 79 ->
# 856 "lexer_cocci.mll"
         ( start_line true;
	  TString(string lexbuf,(get_current_line_type lexbuf)) )
# 2597 "lexer_cocci.ml"

  | 80 ->
let
# 858 "lexer_cocci.mll"
             x
# 2603 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
# 858 "lexer_cocci.mll"
                   ( start_line true;
		     TFloat(x,(get_current_line_type lexbuf)) )
# 2608 "lexer_cocci.ml"

  | 81 ->
let
# 868 "lexer_cocci.mll"
         x
# 2614 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
# 868 "lexer_cocci.mll"
            ( start_line true; TInt(x,(get_current_line_type lexbuf)) )
# 2618 "lexer_cocci.ml"

  | 82 ->
# 870 "lexer_cocci.mll"
                   ( TIso )
# 2623 "lexer_cocci.ml"

  | 83 ->
# 871 "lexer_cocci.mll"
                   ( TRightIso )
# 2628 "lexer_cocci.ml"

  | 84 ->
# 873 "lexer_cocci.mll"
                   ( EOF )
# 2633 "lexer_cocci.ml"

  | 85 ->
# 875 "lexer_cocci.mll"
      ( lexerr "unrecognised symbol, in token rule: " (tok lexbuf) )
# 2638 "lexer_cocci.ml"

  | __ocaml_lex_state -> lexbuf.Lexing.refill_buff lexbuf; __ocaml_lex_token_rec lexbuf __ocaml_lex_state

and char lexbuf =
    __ocaml_lex_char_rec lexbuf 220
and __ocaml_lex_char_rec lexbuf __ocaml_lex_state =
  match Lexing.engine __ocaml_lex_tables __ocaml_lex_state lexbuf with
      | 0 ->
let
# 879 "lexer_cocci.mll"
          x
# 2650 "lexer_cocci.ml"
= Lexing.sub_lexeme_char lexbuf lexbuf.Lexing.lex_start_pos in
# 879 "lexer_cocci.mll"
                                       ( String.make 1 x ^ restchars lexbuf )
# 2654 "lexer_cocci.ml"

  | 1 ->
let
# 881 "lexer_cocci.mll"
                                             x
# 2660 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
# 881 "lexer_cocci.mll"
                                                     ( x ^ restchars lexbuf )
# 2664 "lexer_cocci.ml"

  | 2 ->
let
# 885 "lexer_cocci.mll"
                                  x
# 2670 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
# 885 "lexer_cocci.mll"
                                                     ( x ^ restchars lexbuf )
# 2674 "lexer_cocci.ml"

  | 3 ->
let
# 886 "lexer_cocci.mll"
                 v
# 2680 "lexer_cocci.ml"
= Lexing.sub_lexeme_char lexbuf (lexbuf.Lexing.lex_start_pos + 1)
and
# 886 "lexer_cocci.mll"
                                  x
# 2685 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos (lexbuf.Lexing.lex_start_pos + 2) in
# 887 "lexer_cocci.mll"
 (
          (match v with (* Machine specific ? *)
          | 'n' -> ()  | 't' -> ()   | 'v' -> ()  | 'b' -> () | 'r' -> ()
          | 'f' -> () | 'a' -> ()
	  | '\\' -> () | '?'  -> () | '\'' -> ()  | '\"' -> ()
          | 'e' -> () (* linuxext: ? *)
	  | _ ->
              Common.pr2 ("LEXER: unrecognised symbol in char:"^tok lexbuf);
	  );
          x ^ restchars lexbuf
	)
# 2699 "lexer_cocci.ml"

  | 4 ->
# 899 "lexer_cocci.mll"
      ( Common.pr2 ("LEXER: unrecognised symbol in char:"^tok lexbuf);
        tok lexbuf ^ restchars lexbuf
      )
# 2706 "lexer_cocci.ml"

  | __ocaml_lex_state -> lexbuf.Lexing.refill_buff lexbuf; __ocaml_lex_char_rec lexbuf __ocaml_lex_state

and restchars lexbuf =
    __ocaml_lex_restchars_rec lexbuf 230
and __ocaml_lex_restchars_rec lexbuf __ocaml_lex_state =
  match Lexing.engine __ocaml_lex_tables __ocaml_lex_state lexbuf with
      | 0 ->
# 904 "lexer_cocci.mll"
                                       ( "" )
# 2717 "lexer_cocci.ml"

  | 1 ->
let
# 905 "lexer_cocci.mll"
          x
# 2723 "lexer_cocci.ml"
= Lexing.sub_lexeme_char lexbuf lexbuf.Lexing.lex_start_pos in
# 905 "lexer_cocci.mll"
                                       ( String.make 1 x ^ restchars lexbuf )
# 2727 "lexer_cocci.ml"

  | 2 ->
let
# 907 "lexer_cocci.mll"
                                             x
# 2733 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
# 907 "lexer_cocci.mll"
                                                     ( x ^ restchars lexbuf )
# 2737 "lexer_cocci.ml"

  | 3 ->
let
# 911 "lexer_cocci.mll"
                                  x
# 2743 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
# 911 "lexer_cocci.mll"
                                                     ( x ^ restchars lexbuf )
# 2747 "lexer_cocci.ml"

  | 4 ->
let
# 912 "lexer_cocci.mll"
                 v
# 2753 "lexer_cocci.ml"
= Lexing.sub_lexeme_char lexbuf (lexbuf.Lexing.lex_start_pos + 1)
and
# 912 "lexer_cocci.mll"
                                  x
# 2758 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos (lexbuf.Lexing.lex_start_pos + 2) in
# 913 "lexer_cocci.mll"
 (
          (match v with (* Machine specific ? *)
          | 'n' -> ()  | 't' -> ()   | 'v' -> ()  | 'b' -> () | 'r' -> ()
          | 'f' -> () | 'a' -> ()
	  | '\\' -> () | '?'  -> () | '\'' -> ()  | '\"' -> ()
          | 'e' -> () (* linuxext: ? *)
	  | _ ->
              Common.pr2 ("LEXER: unrecognised symbol in char:"^tok lexbuf);
	  );
          x ^ restchars lexbuf
	)
# 2772 "lexer_cocci.ml"

  | 5 ->
# 925 "lexer_cocci.mll"
      ( Common.pr2 ("LEXER: unrecognised symbol in char:"^tok lexbuf);
        tok lexbuf ^ restchars lexbuf
      )
# 2779 "lexer_cocci.ml"

  | __ocaml_lex_state -> lexbuf.Lexing.refill_buff lexbuf; __ocaml_lex_restchars_rec lexbuf __ocaml_lex_state

and string lexbuf =
    __ocaml_lex_string_rec lexbuf 241
and __ocaml_lex_string_rec lexbuf __ocaml_lex_state =
  match Lexing.engine __ocaml_lex_tables __ocaml_lex_state lexbuf with
      | 0 ->
# 930 "lexer_cocci.mll"
                                               ( "" )
# 2790 "lexer_cocci.ml"

  | 1 ->
let
# 931 "lexer_cocci.mll"
          x
# 2796 "lexer_cocci.ml"
= Lexing.sub_lexeme_char lexbuf lexbuf.Lexing.lex_start_pos in
# 931 "lexer_cocci.mll"
                               ( Common.string_of_char x ^ string lexbuf )
# 2800 "lexer_cocci.ml"

  | 2 ->
let
# 932 "lexer_cocci.mll"
                                            x
# 2806 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
# 932 "lexer_cocci.mll"
                                              ( x ^ string lexbuf )
# 2810 "lexer_cocci.ml"

  | 3 ->
let
# 933 "lexer_cocci.mll"
                               x
# 2816 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
# 933 "lexer_cocci.mll"
                                              ( x ^ string lexbuf )
# 2820 "lexer_cocci.ml"

  | 4 ->
let
# 934 "lexer_cocci.mll"
                v
# 2826 "lexer_cocci.ml"
= Lexing.sub_lexeme_char lexbuf (lexbuf.Lexing.lex_start_pos + 1)
and
# 934 "lexer_cocci.mll"
                       x
# 2831 "lexer_cocci.ml"
= Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos (lexbuf.Lexing.lex_start_pos + 2) in
# 935 "lexer_cocci.mll"
       (
         (match v with
	    | 'n' -> ()  | 't' -> ()   | 'v' -> ()  | 'b' -> () | 'r' -> ()
	    | 'f' -> () | 'a' -> ()
	    | '\\' -> () | '?'  -> () | '\'' -> ()  | '\"' -> ()
	    | 'e' -> ()
	    | '\n' -> ()
	    | '(' -> () | '|' -> () | ')' -> ()
	    | _ -> lexerr "unrecognised symbol:" (tok lexbuf)
	 );
          x ^ string lexbuf
       )
# 2846 "lexer_cocci.ml"

  | 5 ->
# 947 "lexer_cocci.mll"
      ( lexerr "unrecognised symbol: " (tok lexbuf) )
# 2851 "lexer_cocci.ml"

  | __ocaml_lex_state -> lexbuf.Lexing.refill_buff lexbuf; __ocaml_lex_string_rec lexbuf __ocaml_lex_state

and comment check_comment lexbuf =
    __ocaml_lex_comment_rec check_comment lexbuf 252
and __ocaml_lex_comment_rec check_comment lexbuf __ocaml_lex_state =
  match Lexing.engine __ocaml_lex_tables __ocaml_lex_state lexbuf with
      | 0 ->
# 950 "lexer_cocci.mll"
         ( let s = tok lexbuf in check_comment s; start_line true; s )
# 2862 "lexer_cocci.ml"

  | 1 ->
# 952 "lexer_cocci.mll"
      ( let s = tok lexbuf in
        (* even blank line should have a + *)
        check_comment s;
        reset_line lexbuf; s ^ comment check_comment lexbuf )
# 2870 "lexer_cocci.ml"

  | 2 ->
# 956 "lexer_cocci.mll"
        ( pass_zero();
	  if !current_line_started
	  then (start_line true;
		let s = tok lexbuf in s^(comment check_comment lexbuf))
	  else (start_line true; comment check_comment lexbuf) )
# 2879 "lexer_cocci.ml"

  | 3 ->
# 963 "lexer_cocci.mll"
      ( let s = tok lexbuf in
        check_comment s; start_line true; s ^ comment check_comment lexbuf )
# 2885 "lexer_cocci.ml"

  | 4 ->
# 966 "lexer_cocci.mll"
      ( let s = tok lexbuf in
        check_comment s; start_line true; s ^ comment check_comment lexbuf )
# 2891 "lexer_cocci.ml"

  | 5 ->
# 969 "lexer_cocci.mll"
      ( start_line true; let s = tok lexbuf in
        Common.pr2 ("LEXER: unrecognised symbol in comment:"^s);
        s ^ comment check_comment lexbuf
      )
# 2899 "lexer_cocci.ml"

  | __ocaml_lex_state -> lexbuf.Lexing.refill_buff lexbuf; __ocaml_lex_comment_rec check_comment lexbuf __ocaml_lex_state

;;

