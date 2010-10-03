(*
* Copyright 2005-2009, Ecole des Mines de Nantes, University of Copenhagen
* Yoann Padioleau, Julia Lawall, Rene Rydhof Hansen, Henrik Stuart, Gilles Muller
* This file is part of Coccinelle.
* 
* Coccinelle is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, according to version 2 of the License.
* 
* Coccinelle is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
* 
* You should have received a copy of the GNU General Public License
* along with Coccinelle.  If not, see <http://www.gnu.org/licenses/>.
* 
* The authors reserve the right to distribute this or future versions of
* Coccinelle under other licenses.
*)


type sequence =
    Seq of element * sequence
  | Empty
  | SExists of Ast_cocci.meta_name * sequence

and term =
    Atomic of Ast_cocci.rule_elem
  | IfThen of term * term * Ast_cocci.end_info
  | TExists of Ast_cocci.meta_name * term

and element =
    Term of term * dots_bef_aft
  | Or of sequence * sequence
  | DInfo of dots
  | EExists of Ast_cocci.meta_name * element

and dots = 
    Dots
  | Nest of sequence
  | When of dots * sequence

and dots_bef_aft =
    NoDots
  | AddingBetweenDots of term * int (*index of let var*)
  | DroppingBetweenDots of term * int (*index of let var*)

