open Batteries
open Utils.Piet

module V = BatVect
type 'a vec = 'a V.t
type picture_v = colour vec vec * int * int
type 'a array = 'a Utils.Array.t
type picture = colour array array * int * int

type ir = Utils.PietIR.ir

let id x = x

module IRExpansion = struct
  module PI = Utils.PietIR

  type ir_draw = Grow of int | EOP
  [@@deriving show {with_path = false}]

  type ir_mix = P of op | I of ir_draw | L of ir_mix list

  let rec show_ir_mix = function
    | L irml -> (Printf.sprintf "L: %s" @@ List.fold_lefti
                   (fun acc i b -> acc ^ (Printf.sprintf
                                            "    %s, %s\n"
                                            (string_of_int i)
                                            (show_ir_mix b))) "" irml)
    | I ird -> show_ir_draw ird
    | P o -> show_op o

  let expansion_func exp_f acc = function
    | PI.Push a -> exp_f acc (PI.Push a)
    | PI.Input  -> P PInpC :: acc
    | PI.Output -> P POutC :: P PDup :: acc
    | PI.Not    -> P PNot  :: acc
    | PI.Add a  -> P PAdd :: exp_f acc (PI.Push a)
    | PI.Subtract a -> P PSub :: exp_f acc (PI.Push a)
    | PI.Multiply a -> P PMul :: exp_f acc (PI.Push a)
    | PI.Mod a      -> P PMod :: exp_f acc (PI.Push a)
    | PI.Roll (a,b) -> P PRoll :: exp_f (exp_f acc (PI.Push b)) (PI.Push a)
    | PI.Loop ir_l  -> L (List.rev @@ List.fold_left exp_f [] ir_l) :: acc
    | PI.Eop        -> I EOP :: acc
    | PI.Op op      -> P op :: acc

  module Naive = struct

    let expand =
      let rec f acc = function
        | PI.Push a ->
          (match compare a 0 with
           | x when x > 0 -> P PPush :: I (Grow a) :: acc
           | 0 -> P PNot :: f acc (PI.Push 1)
           | _ -> P PSub :: f (f acc (PI.Push 1)) (PI.Push (-a + 1)))
        | y -> expansion_func f acc y in
      List.rev % List.fold_left f []
  end

  module Fast = struct

    module FP = Utils.FastPush

    let push_op_to_irml = function
      | FP.Number x -> [P Utils.Piet.PPush; I (Grow x);]
      | FP.PDup     -> [P Utils.Piet.PDup;]
      | FP.Binary FP.PAdd -> [P Utils.Piet.PAdd;]
      | FP.Binary FP.PSub -> [P Utils.Piet.PSub;]
      | FP.Binary FP.PMul -> [P Utils.Piet.PMul;]
      | FP.Binary FP.PDiv -> [P Utils.Piet.PDiv;]
      | FP.Binary FP.PMod -> [P Utils.Piet.PMod;]

    let expand fpl =
      let fastpush_table =
        fpl
        |> List.map (fun (_, c, l) ->
            (c, List.fold_left (fun a x -> (push_op_to_irml x) @ a) [] l))
        (* prepend entry for 0, now list index = number to be pushed *)
        |> List.cons (2, [P Utils.Piet.PNot; P Utils.Piet.PPush;])
        |> Array.of_list
      in
      let rec f acc = function
        | PI.Push a ->
          if a >= 0 then (snd @@
                          try Array.get fastpush_table a with
                            Invalid_argument s ->
                            let _ = print_endline @@ Printf.sprintf
                                "OOB access fpt %d" a in
                            exit 1
                         ) @ acc
          else (P PSub) :: f (f acc (PI.Push 1)) (PI.Push (- a + 1))
        | y -> expansion_func f acc y in
      List.rev % List.fold_left f []
  end

  let interpret ir_l =
    let rec interpret_main (n1, stack) ir =
      let maphead f v =
        let (h, t) = V.shift v in
        V.prepend (f h) t in
      let maphead2 f v =
        let (a, t) = V.shift v in
        let (b, t) = V.shift t in
        V.prepend (f b a) t in
      let f (n, stack) z =
        match z with
        | PI.Push a -> (n + 1, V.prepend a stack)
        | PI.Input  -> raise (Failure "input unexpected.")
        | PI.Output ->
          (try
             let _ = print_char % char_of_int % V.first @@ stack in
             let _ = flush stdout in
             (n, stack)
           with
             Invalid_argument s ->
             print_endline @@ Printf.sprintf "intc -> %d" (V.first stack);
             raise (Invalid_argument s))
        | PI.Not    -> (n, maphead (fun x -> if x = 0 then 1 else 0) stack)
        | PI.Add a  -> (n, maphead ((+) a) stack)
        | PI.Subtract a -> (n, maphead (fun x -> x - a) stack)
        | PI.Multiply a -> (n, maphead (( * ) a) stack)
        | PI.Mod a      -> (n, maphead (fun x -> (a + x) mod a) stack)
        | PI.Roll (a, b) ->
          let rec go a b c = match a with
            | x when x > 0 ->
              let (h, t) = V.shift c in
              if b <> V.length c then
                (* NOTE: the b - 1 below should actually be b - 2 according to
                   batteries documentation but there is an off-by-one error in
                   library.*)
                go (a - 1) b V.(insert (b - 1) (singleton h) t)
              else go (x - 1) b (V.append h t)
            | x when x < 0 ->
              let y = V.get c (b - 1) in
              let z = V.remove (b - 1) 1 c in
              go (a + 1) b (V.prepend y z)
            | _ -> c in
          (n - a, go a b stack)
        | PI.Loop ir_l  ->
          let inner = V.of_list ir_l in
          let rec go (n2, acc) = match V.first acc with
            | 0 -> (n2, acc)
            | _ -> go (interpret_main (n2, acc) inner) in
          go (n, stack)
        | PI.Eop        -> (n, stack)
        | PI.Op PDup    -> (n + 1, V.prepend (V.first stack) stack)
        | PI.Op PSub    -> (n - 1, maphead2 (-) stack)
        | PI.Op PAdd -> (n - 1, maphead2 (+) stack)
        | _ -> raise (Failure "unexpected operation")
      in
      V.fold_left f (n1, stack) ir
    in
    (* FIXME: magic number for interpreting Towers of Hanoi *)
    interpret_main (-288, V.empty) @@ V.of_list ir_l |> snd

end


module CanonicalDraw = struct

  module IR = Utils.PietIR
  module IRE = IRExpansion

  (* NOTE:
     Use of Naive is restricted to cases when both Naive and Fast overlap. *)
  module IREN = IRExpansion.Naive

  type ir_block = xy * bool * picture_v

  type ir_draw = DrawWhite | Random | Cp of int | Grow of int | Eop
  [@@deriving show {with_path = false}]

  type ir_mix = P of op | I of ir_draw | L of ir_mix list

  let rec upcast = function
    | IRE.P op -> P op
    | IRE.I ir -> (match ir with
        | IRE.Grow a -> I (Grow a)
        | IRE.EOP  -> I (Eop))
    | IRE.L irl -> L (List.map upcast irl)

  let rec fill_rows cur_y (clr_a, w, h) =
    if cur_y = h then (clr_a, w, h)
    else
      let cur_row = V.get clr_a cur_y in
      let black_row = V.make (w - V.length cur_row) Black in
      fill_rows (cur_y + 1)
        (V.modify clr_a cur_y (fun r -> V.concat r black_row), w, h)

  let fill_below = fill_rows 1

  let rec draw_linear_right :
    int * colour * int * picture_v -> ir_mix -> int * colour * int * picture_v =

    fun (depth, cur_clr, sz, (p_clr_a2d, w, h)) ->

      let append_1 clr =
        fill_below (V.modify p_clr_a2d 0 (V.append clr), w + 1, h) in
      let concat_1d dw c_clr_a1d =
        fill_below
          (V.modify p_clr_a2d 0 (fun z -> V.concat z c_clr_a1d), w + dw, h) in
      let rec concat_2d (p_clr_a2d, w, h) (clr_a2d, dw, new_h) =
        if new_h <= h then
          let p_clr_a2d =
            V.foldi (fun i acc row -> V.modify acc i (fun z -> V.concat z row))
              p_clr_a2d clr_a2d in
          fill_rows new_h (p_clr_a2d, w + dw, h)
        else
          let new_p = V.concat p_clr_a2d @@ V.make (new_h - h) V.empty in
          let new_p = fill_rows h (new_p, w, new_h) in
          concat_2d new_p (clr_a2d, dw, new_h) in

      function
      | P op ->
        if cur_clr = White then
          let rand_clr = Green (* 18 |> Random.int |> num_to_colour *) in
          let next_clr = op_next_colour op rand_clr in
          let tl = V.singleton rand_clr |> V.append next_clr in
          (depth, next_clr, 1, concat_1d 2 tl)
        else
          let next_clr = op_next_colour op cur_clr in
          (depth, next_clr, 1, append_1 next_clr)

      | I DrawWhite  ->
        if cur_clr = White then (depth, Blue, 1, append_1 Blue)
        else (depth, White, 1, append_1 White)
      | I Random ->
        let rand_clr = Red (*18 |> Random.int |> num_to_colour*) in
        (depth, rand_clr, 1, append_1 rand_clr)

      (* assert a > 0 *)
      | I Cp a ->
        (depth, cur_clr, a + 1, cur_clr |> V.make a |> concat_1d a)

      (* assert a > 0 *)
      | I Grow a  ->
        (if cur_clr = White then
           let rand_clr = Blue in
           draw_linear_right
             (depth, rand_clr, 1, append_1 rand_clr) (I (Grow a))
         else
           let acc = (depth, cur_clr, sz, (p_clr_a2d, w, h)) in
           match compare sz a with
           | x when x > 0  -> List.fold_left
                                draw_linear_right
                                acc [I DrawWhite; I Random; I (Cp (a-1))]
           | x when x < 0 -> draw_linear_right acc (I (Cp (a-sz)))
           | _  -> acc)

      | I Eop ->
        let temp =
          V.(of_list [
              of_list [White; White; Green; Black;  Cyan;];
              of_list [Black; Black; White; Black;  Cyan;];
              of_list [Black; Green; Green; Green; Black;];
              of_list [Black; Black; Black; Black;  Cyan;];
            ]) in
        (depth, White, 1, concat_2d (p_clr_a2d, w, h) (temp, 5, 4))

      | L (irm_l) ->
        let (_, _, _, (c_clr_a, c_w, c_h)) =
          (* let rand_clr = 18 |> Random.int |> num_to_colour in *)
          List.fold_left
            draw_linear_right
            (depth+1, White, 0, (V.singleton V.empty, 0, 1))
            irm_l in

        let make_vec l =
          let (_, _, _, (arr2d, tv_w, _)) =
            List.fold_left draw_linear_right
              (depth, White, 0, (V.singleton V.empty, 0, 1)) l in
          (V.get arr2d 0, tv_w) in

        let (turn_col, tc_h) =
          if depth mod 2 = 0 then
            (V.singleton White |> V.append Green, 2)
          else
            let (ac_turn_col, ac_turn_col_len) =
              (IREN.expand [IR.Push 3]) @ [IRE.P PPtr]
              |> List.map upcast |> make_vec in
            (V.concat (V.singleton White) ac_turn_col, ac_turn_col_len + 1)
        in

        (* black border of 1 codel on each side *)
        let boundary_w = 1 in

        (* +2 is due to white codels needed between cell and entry/exit *)
        let extra_w = 2 * boundary_w + tc_h + 2 in

        let entry_x = c_w + extra_w - 1 - boundary_w in
        let exit_x = boundary_w in

        (* Construct "container" for child *)
        let concat_below i acc = fun row ->
          V.(backwards row
             |> of_enum
             |> (fun z -> if i = 0 then
                    z |> concat (of_enum @@ backwards turn_col)
                    |> append White |> append (last turn_col)
                  else
                    z |> concat (make tc_h Black)
                    |> append Black |> append Black)
             |> prepend Black
             |> append Black
             |> make 1
             |> concat acc) in

        let set n c v = V.set v n c in

        (* child overlaps with tc_h at one point, and there are two layers
           over entry turn_col, top -> PPtr and second -> White *)
        let extra_h = tc_h + 1 in

        (* vector for entry into loop and starting coordinate *)
        let (loop_vec, lv_w) =
          if depth mod 2 = 0 then
            make_vec [P PDup; P PNot; P PNot; P PPtr]
          else
            [IRE.P PDup; IRE.P PNot; IRE.P PNot;]
            @ (IREN.expand [IR.Multiply 3]) @ [IRE.P PPtr]
            |> List.map upcast |> make_vec in
        let start = (entry_x - (lv_w - 1)) in
        let apply_turn top_row =
          V.foldi (fun i a c -> set (i + start) c a) top_row loop_vec in

        let top_row = V.make (c_w + extra_w) White
                      |> set exit_x (V.last turn_col)
                      |> apply_turn in
        let turning_help_rows =
          V.pop turn_col |> snd
          |> fun tc_pop -> V.mapi
            (fun i c ->
               V.make (c_w + extra_w) Black
               |> set entry_x c
               |> set exit_x (V.get tc_pop (tc_h - 2 - i)))
            tc_pop in
        let new_arr2d = turning_help_rows
                        |> V.concat (V.make 1 top_row)
                        |> fun z -> (V.foldi concat_below z c_clr_a) in

        (depth, White, 1,
         concat_2d (p_clr_a2d, w, h) (new_arr2d, c_w + extra_w, c_h + extra_h))

  let draw_linear irm_l =
    let (_, _, _, full_pic) =
      List.fold_left
        (fun a b -> draw_linear_right a (upcast b))
        (0, White, 0, (V.singleton V.empty, 0, 1))
        irm_l in
    full_pic |> Tuple3.map1 (V.map V.to_array %> V.to_array)
end


(*
   J.num_ops indicates the number of transitions allowed inside a rule for
   the tableau. So it is equal to the desired `rule_width - 1` where
   rule_width is in codel units.
   NOTE: J.num_ops >= 3 is required, otherwise anti-clockwise turns will break.
   It is okay to use 1 <= J.num_ops <= 2 when only clockwise turns are needed
   but thin rules may look ugly.
*)
module Mondrian(J : Utils.S) = struct

  module Dim = Utils.Dim
  module Rules = Utils.RuleLoc(J)

  module TableauLayout = struct

    module IRE = IRExpansion

    type linear_layout = Segment of op V.t
                       | LinLoop of linear_layout V.t
                       | LinEOP

    (* NOTE: The last argument to make_straight has items of variants IRE.P
       and IRE.I Grow only. Furthermore, every Grow is preceded by a PPush. *)
    let rec make_straight acc_v rem cur_v = function
      | [] ->
        let rem = (if J.num_ops = rem then 0 else rem) in
        V.prepend (V.concat cur_v (V.make rem PNop)) acc_v

      | x when rem = 0 ->
        make_straight (V.prepend cur_v acc_v) J.num_ops V.empty x

      | IRE.P PPush :: IRE.I (IRE.Grow n) :: t when rem >= n ->
        let cur_v = V.(concat (make (n - 1) PNop |> append PPush) cur_v) in
        make_straight acc_v (rem - n) cur_v t

      | IRE.P PPush :: IRE.I (IRE.Grow n) :: t when rem >= 2 ->
        let cur_v =
          V.(concat (make (rem - 2) PNop |> append PPush |> append PAdd) cur_v)
        in
        make_straight (V.prepend cur_v acc_v) J.num_ops V.empty
          IRE.(P PPush :: I (Grow (n - rem + 1)) :: t)

      (* NOTE: rem = 1 for this branch so no space for operations *)
      | IRE.P PPush :: IRE.I (IRE.Grow n) :: t ->
        let cur_v = V.append PNop cur_v in
        make_straight (V.prepend cur_v acc_v) J.num_ops V.empty
          IRE.(P PPush :: I (Grow n) :: t)

      | IRE.P op :: t ->
        make_straight acc_v (rem - 1) (V.prepend op cur_v) t
      | IRE.I (IRE.Grow n) :: t ->
        raise (Failure "make_straight received Grow not preceded by PPush.")
      | _ -> raise (Failure "Unexpected arguments for make_straight.")

    (*
       Creates a partial layout using IR. The straight sections are split
       up into vectors of length exactly J.num_ops, so that they can be overlaid
       onto (vertical) rules directly.
    *)
    let to_linlayout =
      let rec go dep irml =
        let rec f (dep, stack, acc) =
          let prev_straight_v =
            lazy (if stack = [] then V.empty
                  else V.map (fun x -> Segment x)
                      (make_straight V.empty J.num_ops V.empty stack)) in
          function
          | (IRE.L irm_l) :: xs ->
            (* PPush :: PPop is to turn safely into the first inner row *)
            let inner =  LinLoop (go (dep + 1) @@
                                  IRE.(P PPush :: P PPop :: irm_l)) in
            let acc = V.concat acc (Lazy.force prev_straight_v)
                      |> V.append inner in
            f (dep, [], acc) xs
          | (IRE.I IRE.EOP) :: xs ->
            let acc = V.concat acc (Lazy.force prev_straight_v)
                      |> V.append LinEOP in
            f (dep, [], acc) xs
          | x :: xs -> f (dep, x :: stack, acc) xs
          | [] -> (dep, [], V.concat acc (Lazy.force prev_straight_v)) in
        let (_, _, acc) = f (dep, [], V.empty) irml in
        acc in
      go 0

    (*
       The program is decomposed into a sequence of Rows and Turns.

       | Row    | >   | >   | Turn v |
       | Turn v | <   | Row | <      |
       | >      | Row | >   | Turn v |
       | ...    | ... | ... | ...    |

       Note: when we speak about rows, we mean the horizontal rows in the
       above table (including the half-turn(s)), not the Row literally.

       The rows may be of different heights (in terms of horizontal rules).
       The Turn at the end of the row records the height (in rules) of the
       previous row for convenience.

       Stick represents a bunch of operations combined on top of a vertical
       rule with height = current_row.height .
       Fence represents a loop; it looks like a 2D array of sticks.
       ChunkEOP is a literal translation of EOP.

       The max number of possible sticks in different rows may be different. Say
       if there is only one row, you can insert n sticks. Then if you have two
       rows, you can insert (n - 1) sticks in both of them. If you have three or
       more rows, you can insert only (n - 2) sticks in the middle ones and
       (n - 1) in the first and last rows. This is because each Turn uses up
       one stick in its entry and exit rows.
    *)
    type chunk = Stick of op list
               | Fence of t
               | ChunkEOP and
    chunkblock = Row of chunk Utils.Vect.t
               | Turn of int and
    t = {
      width : int; (* max number of vertical rules required by a row, including
                      rules used by turn(s) at the edge(s), if present *)
      tot_h : int; (* total number of horizontal rules = sum row_h *)
      row_h : int list; (* heights of individual rows in number of rules *)
      n_row : int;      (* = List.length row_h *)
      blank : int list; (* blank[i] = max_possible_sticks[i] - row_h[i] *)
      cost  : float;
      inner : chunkblock list;
    } [@@deriving show {with_path = false}]

    let meta_chunk = function
      | Stick v -> (1, 1, Stick v)
      | Fence i -> (i.width, i.tot_h, Fence i)
      | ChunkEOP -> (1, 1, ChunkEOP)

    let is_fence = function
      | (_, _, Fence _) -> true
      | _ -> false

    let empty_info = {
      width = 0;
      tot_h = 0;
      row_h = [];
      n_row = 1;
      blank = [];
      cost  = 0.;
      inner = [];
    }

    let wh_cost phi w h =
      let r = float h /. float w in
      let a = float w *. float h in
      a *. (abs_float @@ (if r >= 1. then r else 1./.r) -. phi)**2.0

    let rec layout_of_n prog_meta phi n tot_w =
      let fill n (tot_w, pmeta, info) =
        let new_cost info = info.cost +. wh_cost phi tot_w info.tot_h in
        let init_rem k =
          if n = 1 then tot_w
          else if k = 1 || k = n then tot_w - 1
          else tot_w - 2
        in
        let rec f info = function
          | ([], 1, 0) ->
            let blank =
              (* if the inner thing fit perfectly *)
              if List.(length info.blank = length info.row_h - 1) then
                0 :: info.blank
              else info.blank in
            (false, {info with cost = new_cost info; blank;})
          | (_, 1, 0) ->
            (true, {info with cost = new_cost info;})

          | ([], n, r) ->
            let row_h = info.row_h in
            let inner =
              if n = 1 then info.inner
              else
                let tmp = Row V.empty :: Turn (List.hd row_h) :: info.inner in
                if n = 2 then tmp
                else List.(fold_left (fun a _ -> Row V.empty :: Turn 1 :: a)
                             tmp @@ range 0 `To (n - 3)) in
            let blank =
              if n = 1 then r :: info.blank
              else (tot_w - 1) :: List.make (n - 2) (tot_w - 2)
                   @ r :: info.blank in
            let tot_h = info.tot_h + n - 1 in
            let info = {
              info with tot_h;
                        row_h = List.make (n - 1) 1 @ row_h;
                        n_row = info.n_row + (n - 1);
                        blank;
                        cost = new_cost info;
                        inner;
            } in
            (false, info)

          | ((w, h, dc) :: t, n, r) when w > r ->
            if n = 1 || w > tot_w - 1 || (t <> [] && w > tot_w - 2) then
              (* beta, tumse na (fit) ho payega https://youtu.be/biqHU4BKuLc
                 "Son, you won't be able to do it (fitting the chunk inside)" *)
              (true, info)
            else
              let (turn_h, row_h) = match info.row_h with
                | x :: xs -> (x, 1 :: x :: xs)
                | [] -> raise (Failure "Case should've been caught earlier") in
              let inner = (if r = init_rem n then
                             Turn turn_h :: Row V.empty :: info.inner
                           else Turn turn_h :: info.inner) in
              let info = {
                info with tot_h = info.tot_h + 1;
                          row_h;
                          n_row = 1 + info.n_row;
                          blank = r :: info.blank;
                          inner;
              } in
              f info ((w, h, dc) :: t, n - 1, init_rem (n - 1))

          | ((w, h, ch) :: t, n, r) ->
            let (tot_h, row_h) = match info.row_h with
              | x :: xs ->
                let cur_h = max h x in
                (info.tot_h + cur_h - x, (max h x) :: xs)
              | [] -> (info.tot_h + h, [h]) in
            let cost = info.cost +. match ch with
              | Fence f_info -> f_info.cost
              | _ -> 0. in
            let inner = match info.inner with
              | Row ch_v :: tl -> Row (V.append ch ch_v) :: tl
              | tl -> Row (V.singleton ch) :: tl in
            f {info with tot_h; row_h; cost; inner;} (t, n, r - w)
        in
        f info (pmeta, n, init_rem n)
      in
      let (leftover, info) =
        fill n (tot_w, V.to_list prog_meta, {empty_info with width = tot_w;}) in
      if leftover then
        layout_of_n prog_meta phi n (tot_w + 1)
      else
        {info with cost = info.cost +. wh_cost phi info.width info.tot_h}

    let fence_extra_w = Dim.Boxdim 1

    (*
       The placement logic is slightly complicated.
       Example:
       If tmp.tot_h = 1, the inner part will not share any vertical rules
       with the parent loop, so 2 columns are required. Otherwise, one
       vertical rule is shared, so only 1 additional column is required.
       To understand the use of "magic numbers" / if-else values for variables,
       see `../docs/tableau.md`.
    *)
    let rec placement phi progv =
      let f phi = function
        | Segment op_v -> Stick (V.to_list op_v)
        | LinEOP -> ChunkEOP
        | LinLoop pv ->
          let phi = max 1. (phi -. 0.2) in
          let tmp = placement phi pv in
          let extra_h = 1 in
          let extra_w = Dim.int_of_boxdim fence_extra_w in
          let min_w = 2 in
          let outer_w = max min_w (tmp.width + extra_w) in
          let tot_h = tmp.tot_h + extra_h in
          Fence {
            width = outer_w;
            tot_h;
            row_h = tmp.row_h;
            n_row = tmp.n_row;
            blank = tmp.blank;
            cost  = tmp.cost +. wh_cost phi outer_w tot_h;
            inner = tmp.inner;
          }
      in
      let prog_meta = V.map (meta_chunk % (f phi)) progv in
      let is_tall = V.exists (fun (_, h, _) -> h > 1) prog_meta in

      let inject_w f a (w, _, _) = f a w in
      let tot_len = V.fold_left (inject_w (+)) 0 prog_meta in
      let max_inner_w = V.filter is_fence prog_meta
                        |> V.fold_left (inject_w max) 1 in

      (* TODO: think about weird edge case -- tot_len <= 4 && is_tall *)
      if tot_len <= 4 && (not is_tall) then {
        width = tot_len;
        tot_h = 1;
        row_h = [1];
        n_row = 1;
        blank = [0];
        cost  = wh_cost phi tot_len 1;
        inner = [Row (V.map (fun (_, _, x) -> x) prog_meta)];
      }
      else
        let min_outer_w = max_inner_w + (if is_tall then 1 else 2) in
        let rec go n =
          let info = layout_of_n prog_meta phi n min_outer_w in
          function
          | Some best when best.cost <= info.cost ->
            {
              best with row_h = List.rev best.row_h;
                        blank = List.rev best.blank;
                        inner = List.rev best.inner;
            }
          | _ -> go (n + 2) (Some info)
        in
        go 1 None

    let ir_mix_list_to_layout = placement Utils.golden_ratio % to_linlayout

  end

  module TableauGrid = struct

    type dir = LtoR | RtoL
    [@@deriving show {with_path = false}]

    let flip_dir = function
      | LtoR -> RtoL
      | RtoL -> LtoR

    type pre_sem = Conditional | Unconditional of dir
    [@@deriving show {with_path = false}]

    type post_sem = LoopReentry | SharpTurn of op list
    [@@deriving show {with_path = false}]

    type rot = CW | ACW
    [@@deriving show {with_path = false}]

    (*
       Flow semantics:
       * PreTurnTunnel -> Conditional : CW <=> LtoR, ACW <=> RtoL

       Usage:
       * PreTurnTunnel ->
         - at the end of a row for changing semantic rows
           (CW, Unconditional LtoR) and (ACW, Unconditional RtoL)
         - conditionally entering a loop
         - at the bottom of the "exit route" of a loop after going through a
           loop's inner contents
           (CW, Unconditional RtoL) and (ACW, Unconditional LtoR)
       * PostTurnTunnel ->
         - (re-)entering a loop (LoopReentry)
         - first rule after changing semantic rows
           SharpTurn PPush :: PPop :: PNop :: PNop :: ...
         - first rule on using a loop's inner contents
           SharpTurn code1 :: code2 :: code3 :: ...
           code1 and code2 are guaranteed to be PPush and PPop

       These v_edges have additional constraints:
       * VPreTurnTunnel _ Conditional ->
         - Requires a PPtr codel immediately after the edge codels. Its colour
           dictates the edge codel colours.
       * VPostTurnTunnel _ LoopReentry ->
         - Requires a capture codel below the PPtr codel. The capture -> PPtr
           transition gives a PPtr operation.
         - The PPtr codel is logically before the edge codels.
         - The colour of the PPtr codel specifies the colour of the first
           edge codel and hence the entire sequence.
       * VPostTurnTunnel _ SharpTurn _ ->
         - Requires a PPtr codel immediately logically before the edge codels.
         - The colour of the PPtr codel specifies the colour of the first
           edge codel and hence the entire sequence.
       * VEOPTunnel _ ->
         - Regardless of anything else, the opposite edge (along the direction)
           of flow should be replaced with VSolid.
         - The exit is should be the same colour as the codel logically after.
         - The EOP pattern is created as follows

           | Ptr  | Dup | Rand |      |     | Ptr  | <EOP |
           |      |     |      |      |     | Dup  |      |
           |      |     |      |      |     | Rand |      |
           |      |     |      |      |     |      |      |
           |      |     |      |      |     |      |      |
           |      |     |      |      |     |      |      |
           | Rand |     |      |      |     |      |      |
           | Dup  |     |      |      |     |      |      |
           | Ptr  |     |      | Rand | Dup | Ptr  |      |

           | EOP> | Ptr  |     |      | Rand | Dup | Ptr  |
           |      | Dup  |     |      |      |     |      |
           |      | Rand |     |      |      |     |      |
           |      |      |     |      |      |     |      |
           |      |      |     |      |      |     |      |
           |      |      |     |      |      |     |      |
           |      |      |     |      |      |     | Rand |
           |      |      |     |      |      |     | Dup  |
           |      | Ptr  | Dup | Rand |      |     | Ptr  |
    *)
    type v_edge = VBoundary            (* Boundary of the program          *)
                | VSolid               (* Dummy edges, fully black (solid) *)
                | VOpTunnel of (dir * op list)  (* For TableauLayout.Stick *)
                | VNopTunnel
                | VEOPTunnel of dir
                (* Turn tunnels touch a "PPtr codel" *)
                | VPreTurnTunnel of (rot * pre_sem)   (* Tunnel before PPtr *)
                | VPostTurnTunnel of (dir * post_sem) (* Tunnel after PPtr  *)
    [@@deriving show {with_path = false}]

    let nop_tunnel_ops = List.make (J.num_ops) PNop

    let op_tunnel_ops_v = function
      | (LtoR, ops) -> ops
      | (RtoL, ops) -> List.rev ops

    let eop_tunnel_ops_v = function
      | LtoR -> PPush :: List.make (J.num_ops - 1) PNop
      | RtoL -> PNop :: PNop :: PPush :: List.make (J.num_ops - 3) PNop

    let rec pre_turn_ops_v = function
      | (CW, Conditional) -> List.make J.num_ops PNop
      | (ACW, Conditional) -> List.rev @@ PNop :: PNop :: PPush :: PMul
                                          :: List.make (J.num_ops - 4) PNop
      | (CW, Unconditional LtoR) -> PPush :: List.make (J.num_ops - 1) PNop
      | (ACW, Unconditional LtoR) -> PNop :: PNop :: PPush
                                     :: List.make (J.num_ops - 3) PNop
      | (a, Unconditional b) ->
        List.rev @@ pre_turn_ops_v (a, Unconditional (flip_dir b))

    let rec post_turn_ops_v =
      let pre_pre_conditional_turn_ops =
        PDup :: PNot :: PNot :: List.make (J.num_ops - 3) PNop in
      function
      | (LtoR, LoopReentry) -> pre_pre_conditional_turn_ops
      | (LtoR, SharpTurn opl) -> opl
      | (RtoL, a) -> List.rev @@ post_turn_ops_v (LtoR, a)

    let ops_v = function
      | VBoundary -> None
      | VSolid -> None
      | VOpTunnel a -> Some (op_tunnel_ops_v a)
      | VNopTunnel -> Some (nop_tunnel_ops)
      | VEOPTunnel _ -> Some (nop_tunnel_ops)
      | VPreTurnTunnel a -> Some (pre_turn_ops_v a)
      | VPostTurnTunnel a -> Some (post_turn_ops_v a)

    let noplike = PPush :: PPop :: List.make (J.num_ops - 2) PNop

    type lr = L | R
    [@@deriving show {with_path = false}]

    (*
       Flow semantics:
       * PreTurnTunnel  -> up to down, in contact with a "Ptr codel"
                           CW <=> L and ACW <=> R

       * PostTurnTunnel -> down to up, in contact with a "Ptr codel"
                           CW <=> R and ACW <=> L

       * PreReentryTunnel -> down to up, NOT in contact with a "Ptr codel"
                             CW <=> R and ACW <=> L

       Usage:
       * PreTurnTunnel    -> at the bottom of a row when changing semantic rows,
                             just before entering a loop's inner contents
       * PostTurnTunnel   -> at the bottom of the "exit route" for a loop
       * PreReentryTunnel -> at the top of the "exit route" for a loop
       * PostTurnPreReentry -> in the special case when the loop is flat,
                                     the same edge has to serve both functions

       |  > > >  ptunnel >>  p is a codel that gives a PPtr transition from z
       |         z|    |     z is a coloured codel as we need a CW turn here
       |         ^|    |     tunnel is the v_edge variant (PostTurnTunnel CW)
       |          |    |
       |=========^|    |
       |========= |    |   === lines denote the LoopRetTunnel
       |=========^|    |   flow passes through the right side as depicted by ^
       |========= |    |

       The LoopRetTunnel is unnecessary for clockwise entry, but it is needed
       for anticlockwise entry, so we will use it in both cases for consistency.
       We only need an lr value for LoopRetTunnel as CW <=> R and ACW <=> L.
    *)
    type h_edge = HBoundary              (* Boundary of the program  *)
                | HSolid                 (* Dummy edges, fully solid *)
                | HNopTunnel of lr
                | HPreTurnTunnel of lr    (* Tunnel before PPtr *)
                | HPostTurnTunnel of lr   (* Tunnel after PPtr  *)
                | HPreReentryTunnel of lr
                | HPostTurnPreReentry of lr
    [@@deriving show {with_path = false}]

    let pre_turn_ops_h = function
      | L -> pre_turn_ops_v (CW, Unconditional LtoR)
      | R -> pre_turn_ops_v (ACW, Unconditional LtoR)

    (* For the following three, flow is from down to up, while painting will
       be done from up to down. So we must reverse the operation lists. *)
    let post_turn_ops_h = List.rev noplike

    let pre_reentry_ops_h = function
      | L -> List.rev @@ pre_turn_ops_v (ACW, Unconditional LtoR)
      | R -> List.rev @@ pre_turn_ops_v (CW, Unconditional LtoR)

    let post_turn_pre_reentry_ops_h = function
      | L -> List.rev @@ PNop :: PPush :: List.make (J.num_ops - 2) PNop
      | R -> List.rev @@ PPush :: PPop :: PPush
                         :: List.make (J.num_ops - 3) PNop

    let ops_h = function
      | HBoundary -> None
      | HSolid -> None
      | HNopTunnel lr -> Some (lr, nop_tunnel_ops)
      | HPreTurnTunnel lr -> Some (lr, pre_turn_ops_h lr)
      | HPostTurnTunnel lr -> Some (lr, post_turn_ops_h)
      | HPreReentryTunnel lr -> Some (lr, pre_reentry_ops_h lr)
      | HPostTurnPreReentry lr -> Some (lr, post_turn_pre_reentry_ops_h lr)

    type 'a array = 'a Utils.Array.t
    type edge_grid = (v_edge array array) * (h_edge array array)
    [@@deriving show {with_path = false}]

    type out_turn = DoesNotExist
                  | ExistsCompleted
                  | ExistsIncomplete
    [@@deriving show {with_path = false}]

    let sign_of_dir = function
      | LtoR -> 1
      | RtoL -> -1

    let rot_of_dir = function
      | LtoR -> CW
      | RtoL -> ACW

    let map_at i f a =
      let v = Array.get a i in
      Array.set a i (f v)

    let set_ret i x a = Array.set a i x; a

    (* TODO: add a debug parameter to check before overwriting. *)
    (* 0 <= ix < width *)
    let tweak_grid_v (edge : v_edge) ((ve_a, he_a), iy, ix) =
      if iy < Array.length ve_a then
        ve_a |> map_at iy (set_ret ix edge)
      else
        raise (Failure "There is no edge on the side of the tableau")

    (* TODO: add a debug parameter to check before overwriting. *)
    (* 0 <= ix < width + 1 *)
    let tweak_grid_h (edge : h_edge) ((ve_a, he_a), iy, ix) =
      if iy < Array.length he_a then
        he_a |> map_at iy (set_ret ix edge)
      else
        raise (Failure "There is no edge at the bottom of the tableau.")

    type t = {
      (* supplied from outside *)
      grid : edge_grid;   (* represents the full picture *)
      iy : int;           (* cursor y *)
      ix : int;           (* cursor x *)
      dir : dir;
      random : bool;
      in_turn : (int * int) option; (* (iy, ix) of previous out_turn, if any *)

      (* computed from layout given *)
      width : int;        (* width of the usable grid *)
      tot_h : int;        (* height of the usable grid *)
      out_turn : out_turn;
      cur_height : int;   (* height of current semantic row *)
      nblank : int;       (* number of blanks in current semantic row *)
      chv : TableauLayout.chunk Utils.Vect.t; (* chunks in current semantic row *)
    }
    [@@deriving show {with_path = false}]

    let move_ix p n = {p with ix = p.ix + n * sign_of_dir p.dir}

    let grid_w_cursor p = (p.grid, p.iy, p.ix)

    let add_noptunnel1 p =
      tweak_grid_v VNopTunnel (grid_w_cursor p);
      move_ix p 1

    let add_blank1 p =
      let p = add_noptunnel1 p in
      {p with nblank = p.nblank - 1}

    let add_noptunnels p n =
      if n = 0 then p else
        List.(fold_left (fun p _ -> add_noptunnel1 p) p @@ range 0 `To (n - 1))

    let add_blanks p n =
      let p = add_noptunnels p n in
      {p with nblank = p.nblank - n}

    let add_tail ~random p n =
      if not random then add_blanks p n
      else
        let proc_dummy p =
          tweak_grid_v VSolid (grid_w_cursor p);
          move_ix p 1 in
        Enum.take n (Random.enum_bool ())
        |> Enum.fold (fun p b -> if b then proc_dummy p else add_blank1 p) p

    (*
       Fixing flow for turns
       ---------------------

       Let @ denote a vertical turn tunnel and the flow be indicated by arrows.
       Let ==== denote solid horizontal rules and @--- a horizontal turn tunnel.
       Let N denote a NopTunnel and P denote the "post turn tunnel", i.e. the
       one with PPush :: PPop :: Nop :: Nop :: ... following the @---.

       The first situation is bad:

        >> @    |    |         >> N >> @    |
           |v   |    |            |    |v   |
           .    .    .            .    .    .
           .    .    .            .    .    .
           |v   |    |            |    |v   |
           *====*@---*====*       *====*@---*====*
                P                   << P<

       as the flow doesn't turn correctly. The second depicts the correction.

       Note that P and @ have to be on the same vertical rule. We cannot assign
       the rule for P when @'s position is assigned as P's position will be
       determined by the chunks in its (P's) semantic row and we are assigning
       positions for one semantic row at a time.

       So when we attempt to assign a position to P, there are three cases
       1. P.x = @.x -> OK
       2. P.x > @.x -> @ must be moved to the right -> move_out_turn
       3. P.x < @.x -> P must be moved to the right -> move_in_turn

       Of course, the directions will flip for an anticlockwise turn.
    *)

    let cond_turn_ops = rot_of_dir %> fun c -> pre_turn_ops_v (c, Conditional)

    let move_out_turn p iy ix dx =
      let p = add_blanks {p with iy; ix; dir = flip_dir p.dir;} dx in
      let ve = VPreTurnTunnel (rot_of_dir p.dir, Unconditional p.dir) in
      tweak_grid_v ve (grid_w_cursor p)

    let post_in_turn_ops = noplike

    (*
               v              v
              |@---        ---@|
        ix,iy |<        ix,iy >|
       -------|         -------|
         RtoL             LtoR
    *)
    let insert_sharp_turn ops p = (
      (match p.dir with
       | RtoL -> tweak_grid_h (HPreTurnTunnel L) (p.grid, p.iy - 1, p.ix + 1)
       | LtoR -> tweak_grid_h (HPreTurnTunnel R) (p.grid, p.iy - 1, p.ix));
      tweak_grid_v
        (VPostTurnTunnel (p.dir, SharpTurn ops)) (grid_w_cursor p);
    )

    let move_in_turn p dx = add_blanks {p with dir = flip_dir p.dir;} dx

    let rec add_in_turn ~entry p = match p.in_turn with
      | None -> p
      | Some (ot_iy, ot_ix) ->
        let (pinned, ops) = entry in
        if not pinned && p.random && p.nblank > 0
           && Random.int p.width < p.nblank then
          p |> add_blank1 |> add_in_turn ~entry
        else
          (* if p.sign = -1 && p.ix < ot_ix then move_in_turn (right)
             else if p.sign = -1 && p.ix > ot_ix then move_out_turn (right)
             else if p.sign = +1 && p.ix < ot_ix then move_out_turn (left)
             else if p.sign = +1 && p.ix > ot_ix then move_in_turn (left)
             See the comment "Fixing flow for turns" for details. *)
          let p_sign = sign_of_dir p.dir in
          let dx = (p.ix - ot_ix) * p_sign in (
            let p = match dx with
              | dx when dx > 0 -> move_in_turn p dx
              | dx when dx < 0 -> (move_out_turn p ot_iy ot_ix (-dx); p)
              | _ -> p in
            insert_sharp_turn ops p
          );
          move_ix {p with in_turn = None} 1

    let lrix ~downflow ix = Tuple2.map2 ((+) ix) % function
        | LtoR when downflow -> (L, 1)
        | LtoR -> (R, 0)
        | RtoL when downflow -> (R, 0)
        | RtoL -> (L, 1)

    let make_side_channel (lr, ix) m n grid =
      let f iy = tweak_grid_h (HNopTunnel lr) (grid, iy, ix) in
      List.(iter f @@ range m `To n)

    let rec add_out_turn p = match p.out_turn with
      | DoesNotExist
      | ExistsCompleted -> p
      | ExistsIncomplete ->
        if p.random && p.nblank > 0 && Random.int p.width < p.nblank then
          p |> add_blank1 |> add_out_turn
        else (
          let ve = VPreTurnTunnel (rot_of_dir p.dir, Unconditional p.dir) in
          tweak_grid_v ve (grid_w_cursor p);
          if p.cur_height > 1 then (
            let lrix = lrix ~downflow:true p.ix p.dir in
            make_side_channel lrix p.iy (p.iy + p.cur_height - 2) p.grid
          );
          move_ix {p with in_turn = Some (p.iy, p.ix)} 1
        )

    let rec make_mesh ?(random = false) layout =
      let open TableauLayout in
      let rec full ~entry layout p =
        let proc_chunk p = move_ix p % function
            | Stick opl ->
              tweak_grid_v (VOpTunnel (p.dir, opl))
                (grid_w_cursor p); 1
            | ChunkEOP -> tweak_grid_v (VEOPTunnel p.dir) (grid_w_cursor p); 1
            | Fence lyt ->
              (* Create entry / re-entry column *)
              tweak_grid_v
                (VPostTurnTunnel (p.dir, LoopReentry)) (grid_w_cursor p);
              let last_iy = p.iy + lyt.tot_h - 1 in
              let (lr, ix_plus_dx) = lrix ~downflow:false p.ix p.dir in
              if lyt.tot_h > 2 then (
                tweak_grid_h (HPreReentryTunnel lr) (p.grid, p.iy, ix_plus_dx);
                tweak_grid_h (HPostTurnTunnel lr)
                  (p.grid, last_iy - 1, ix_plus_dx);
                if lyt.tot_h > 3 then
                  make_side_channel (lr, ix_plus_dx)
                    (p.iy + 1) (last_iy - 2) p.grid;
              )
              else (* lyt.tot_h = 2; loop has a body even if it was empty *)
                tweak_grid_h (HPostTurnPreReentry lr) (p.grid, p.iy, ix_plus_dx);
              let tmp = (rot_of_dir p.dir, Unconditional (flip_dir p.dir)) in
              tweak_grid_v (VPreTurnTunnel tmp) (p.grid, last_iy, p.ix);

              let p = move_ix p 1 in
              let p = add_noptunnels p (lyt.width - 2) in
              let tmp = (rot_of_dir p.dir, Conditional) in
              tweak_grid_v (VPreTurnTunnel tmp) (grid_w_cursor p);

              (* Surrounding channels are complete. Prep for recursive call. *)
              let p_inner = {
                grid = p.grid;
                iy = p.iy + 1;
                ix = p.ix;
                dir = flip_dir p.dir;
                random = p.random;
                in_turn = Some (p.iy, p.ix);
                (* Dummy values *)
                width = 0;
                tot_h = 0;
                out_turn = ExistsIncomplete;
                cur_height = 0;
                nblank = 0;
                chv = V.empty;
              } in
              let ungentlemanly = Failure "Inner loop made incorrectly." in
              let (first_ops, inner) = match lyt.inner with
                | Row chv :: tl -> (match V.shift chv with
                    | (Stick opl, chv) -> (opl, Row chv :: tl)
                    | _ -> raise ungentlemanly)
                | _ -> raise ungentlemanly in
              let entry = (true, first_ops) in
              let old_width = lyt.width in
              let width = lyt.width -
                          Dim.int_of_boxdim TableauLayout.fence_extra_w in
              let lyt = {
                lyt with width;
                         inner;
              } in
              let _ = full ~entry lyt p_inner in
              old_width
        in

        let rec proc_semrow ~entry p =
          if p.random then
            if V.is_empty p.chv then
              add_out_turn p
              |> (fun p -> add_tail ~random:true p p.nblank)
            else if p.nblank > 0 && Random.int p.width < p.nblank then
              add_blank1 p |> proc_semrow ~entry
            else
              let (ch, chv) = V.shift p.chv in
              let p = (proc_chunk p ch) in
              proc_semrow ~entry {p with chv;}
          else
            add_in_turn ~entry p
            |> (fun p -> V.fold_left proc_chunk p p.chv)
            |> (fun p -> {p with chv = V.empty;}) (* doesn't matter actually *)
            |> (fun p -> add_tail ~random:false p p.nblank)
            |> add_out_turn
        in

        let prep_l_p ~new_inner ~chv ~out_turn l p =
          match l.row_h, l.blank with
          | h :: hs, b :: bs ->
            let p = {
              p with width = layout.width;
                     tot_h = layout.tot_h;
                     out_turn;
                     cur_height = h;
                     nblank = b;
                     chv;
            } in
            let (l : TableauLayout.t) = {
              l with row_h = hs;
                     blank = bs;
                     inner = new_inner;
            } in
            (l, p)
          | [], _ :: _ -> raise (Failure "row_h malformed.")
          | _ :: _, [] -> raise (Failure "nblank malformed.")
          | [], [] -> raise (Failure "row_h and nblank malformed.")
        in

        let rec pick_chv (l, p) = match l.inner with
          | [Row chv] ->
            prep_l_p ~new_inner:[] ~chv ~out_turn:DoesNotExist l p
          | Row chv :: Turn _ :: tl ->
            prep_l_p ~new_inner:tl ~chv ~out_turn:ExistsIncomplete l p
          | _ -> raise (Invalid_argument "Chunkblock list malformed.")
        in

        if layout.inner = [] then p
        else
          let (layout, p) = pick_chv (layout, p) in
          let entry = if fst entry then entry else (false, noplike) in
          let p = proc_semrow ~entry p in
          let p = move_ix p (-1) in
          let p = {p with iy = p.iy + p.cur_height;
                          dir = flip_dir p.dir;} in
          (* later rows do not need special treatment for entry *)
          full ~entry:(false, noplike) layout p
      in

      let width, height = layout.width, layout.tot_h in
      let v = Array.make_matrix height width VSolid in
      let h = Array.make_matrix (height - 1) (width + 1) HSolid in
      let grid = (v, h) in
      full ~entry:(false, []) layout {
        grid;
        iy = 0;
        ix = 0;
        dir = LtoR;
        random;
        in_turn = None;

        (* dummy values *)
        width = 0;
        tot_h = 0;
        out_turn = ExistsIncomplete;
        cur_height = 0;
        nblank = 0;
        chv = V.empty;
      }

  end

  module TableauDomains = struct

    module TG = TableauGrid

    type lr = TG.lr = L | R
    [@@deriving show {with_path = false}]
    type ud = U | D
    [@@deriving show {with_path = false}]
    type merge_dir = UD of ud | LR of lr
    [@@deriving show {with_path = false}]

    let num_of_merge_dir = function
      | LR R -> 0
      | UD U -> 1
      | LR L -> 2
      | UD D -> 3

    let merge_dir_of_num = function
      | 0 -> Some (LR R)
      | 1 -> Some (UD U)
      | 2 -> Some (LR L)
      | 3 -> Some (UD D)
      | _ -> None

    let gen_next f = num_of_merge_dir %> f
                     %> merge_dir_of_num
                     %> function
                       | Some x -> x
                       | None -> raise (Invalid_argument "gen_next")

    let cw_next = gen_next (fun x -> (x + 3) mod 4)
    let acw_next = gen_next (fun x -> (x + 1) mod 4)

    type mobility = {
      u : bool; d : bool;
      l : bool; r : bool;
    }

    let mobility_v =
      let open TableauGrid in
      let default = {u = false; d = true; l = true; r = true;} in
      function
      | VSolid -> {u = true; d = true; l = true; r = true}
      | VNopTunnel -> default
      | VOpTunnel _ -> default
      | VEOPTunnel _ -> default
      | VBoundary -> {u = true; d = true; l = false; r = false;}
      | VPreTurnTunnel _ -> {u = false; d = true; l = false; r = false;}
      | VPostTurnTunnel _ -> {u = false; d = true; l = false; r = false;}

    let mobility_h =
      let open TableauGrid in
      let build b = function
        | Some L -> {u = b; d = b; l = false; r = true;}
        | Some R -> {u = b; d = b; l = true; r = false;}
        | None -> {u = b; d = b; l = true; r = true;} in
      function
      | HSolid -> build true None
      | HNopTunnel lr -> build true (Some lr)
      | HBoundary -> build false None
      | HPreTurnTunnel lr -> build false (Some lr)
      | HPostTurnTunnel lr -> build false (Some lr)
      | HPreReentryTunnel lr -> {(build false (Some lr)) with d = true;}
      | HPostTurnPreReentry lr -> build false (Some lr)

    let replace_with_v = curry @@ function
      | TG.VSolid, _ -> true
      | TG.VNopTunnel, TG.VSolid -> false
      | TG.VNopTunnel, _ -> true
      | TG.VBoundary, TG.VBoundary -> true
      | _, _ -> false

    let replace_with_h = curry @@ function
      | TG.HSolid, _ -> true
      | TG.HNopTunnel _, TG.HSolid -> false
      | TG.HNopTunnel _, _ -> true
      | TG.HBoundary, TG.HBoundary -> true
      | _, _ -> false

    let eff_lr =
      let open TableauGrid in
      function
      | HBoundary -> None
      | HSolid -> None
      | HNopTunnel lr -> Some lr
      | HPreTurnTunnel lr -> Some lr
      | HPostTurnTunnel lr -> Some lr
      | HPreReentryTunnel lr -> Some lr
      | HPostTurnPreReentry lr -> Some lr

    let eff_ud =
      let open TableauGrid in
      function
      | VSolid
      | VBoundary -> None
      | VNopTunnel
      | VOpTunnel _
      | VEOPTunnel _
      | VPreTurnTunnel _
      | VPostTurnTunnel _ -> Some U

    type merge = CutPaste | ExtendOver

    let mergetype_v = function
      | UD _ -> ExtendOver
      | LR _ -> CutPaste

    let mergetype_h = function
      | UD _ -> CutPaste
      | LR _ -> ExtendOver

    let cutpaste_v _ _ = true

    let cutpaste_h a b =
      let lra = eff_lr a in
      let lrb = eff_lr b in
      lrb = lra || lra = None || lrb = None

    let extendover_h a = (eff_lr a = None)

    let extendover_v a = (eff_ud a = None)

    (*
       Merges are of two types:
       * cutpaste : when one edge is put on top of another
       * extendover : when one edge is extended and the other is removed
    *)
    let merge_f mergetype mobility replace_with extendover cutpaste a b mdir =
      let go_extendover a_m_udlr b_m_durl =
        if a_m_udlr then
          if replace_with b a && extendover b then Some a
          else if replace_with a b && b_m_durl && extendover a then Some b
          else None
        else
          None in
      let go_cutpaste a_m_udlr b_m_durl =
        if a_m_udlr && cutpaste a b then
          if replace_with b a then Some a
          else if replace_with a b && b_m_durl then Some b
          else None
        else
          None in
      let pick_f = mergetype %> function
          | CutPaste -> go_cutpaste
          | ExtendOver -> go_extendover in
      let mob_a = mobility a in
      let mob_b = mobility b in
      let z = match mdir with
        | UD U -> (mob_a.u, mob_b.d)
        | UD D -> (mob_a.d, mob_b.u)
        | LR L -> (mob_a.l, mob_b.r)
        | LR R -> (mob_a.r, mob_b.l) in
      uncurry (pick_f mdir) z

    let merge_v = merge_f
        mergetype_v mobility_v replace_with_v extendover_v cutpaste_v
    let merge_h = merge_f
        mergetype_h mobility_h replace_with_h extendover_h cutpaste_h

    type edge = VE of TG.v_edge | HE of TG.h_edge

    type flexbox = {
      x : Dim.boxdim; y : Dim.boxdim;
      w : Dim.boxdim; h : Dim.boxdim;
      u : TG.h_edge; d : TG.h_edge;
      l : TG.v_edge; r : TG.v_edge;
    }
    [@@deriving show {with_path = false}]

    let get_yx fb = Tuple2.mapn Dim.int_of_boxdim (fb.y, fb.x)
    let get_wh fb = Tuple2.mapn Dim.int_of_boxdim (fb.w, fb.h)
    let get_abs_wh fb abs_x_a abs_y_a =
      let (iy, ix) = get_yx fb in
      let (w, h) = get_wh fb in
      Dim.(sub_codeldim abs_x_a.(ix + w) abs_x_a.(ix),
           sub_codeldim abs_y_a.(iy + h) abs_y_a.(iy))

    let dummy_box = {
      x = Dim.Boxdim 0; y = Dim.Boxdim 0;
      w = Dim.Boxdim 0; h = Dim.Boxdim 0;
      u = TG.HSolid; d = TG.HSolid;
      l = TG.VSolid; r = TG.VSolid;
    }

    (* Creates an array of 1x1 flexible boxes out of a grid structure. *)
    let make_box_array ~width ~height p =
      let Dim.Boxdim width = width in
      let Dim.Boxdim height = height in
      let (ve_a, he_a) = TG.(p.grid) in
      let f iy ix =
        let x = Dim.Boxdim ix in
        let y = Dim.Boxdim iy in
        let w = Dim.Boxdim 1 in
        let h = Dim.Boxdim 1 in
        let u = if iy = 0 then TG.HBoundary else he_a.(iy - 1).(ix) in
        let d = if iy = height - 1 then TG.HBoundary else he_a.(iy).(ix) in
        let l = if ix = 0 then TG.VBoundary else ve_a.(iy).(ix - 1) in
        let r = if ix = width - 1 then TG.VBoundary else ve_a.(iy).(ix) in
        {x; y; w; h; u; d; l; r;}
      in
      Array.(make_matrix height width dummy_box
             |> mapi (fun iy -> mapi (fun ix _ -> f iy ix)))

    type merged_box = Box of flexbox | Merged of int * int
    [@@deriving show {with_path = false}]

    type domains = merged_box array array
    [@@deriving show {with_path = false}]

    let read boxes iy ix = Array.(get (Cap.get boxes iy) ix)

    let rec get_parent boxes_rdonly iy ix =
      let z = read boxes_rdonly iy ix in
      match z with
      | Box fbox -> fbox
      | Merged (iy', ix') -> get_parent boxes_rdonly iy' ix'

    let flexbox_eq fb fb' = (fb.x = fb'.x && fb.y = fb'.y)

    let rec merge_pair fb fb' = function
      | LR R ->
        (match merge_v fb.r fb'.r (LR R),
               merge_h fb.u fb'.u (LR R),
               merge_h fb.d fb'.d (LR R) with
        | Some r, Some u, Some d ->
          Ok {fb with w = Dim.add_boxdim fb.w fb'.w; r; u; d;}
        | _ -> Bad ())
      | LR L -> merge_pair fb' fb (LR R)
      | UD D ->
        (match merge_h fb.d fb'.d (UD D),
               merge_v fb.l fb'.l (UD D),
               merge_v fb.r fb'.r (UD D) with
        | Some d, Some l, Some r ->
          Ok {fb with h = Dim.add_boxdim fb.h fb'.h; d; l; r;}
        | _ -> Bad ())
      | UD U -> merge_pair fb' fb (UD D)

    (*
       fbox is the primary box in question.
       iy, ix are the indices used to look for the first "side box" in boxes.
       mdir is the primary direction of merging.
       len is the dimension of fbox along the edge being merged.
       The direction parallel to len is referred to as "tangential".

       We try to "collapse" the side boxes, in a direction perpendicular
       to mdir, and then merge the result with fbox along mdir, if possible.
       Possible failure causes:
       - one or more internal merges may not be possible
       - the normal direction sizes for side boxes are not all equal
       - the sum of tangential sizes for side boxes is not equal to l
       - the final merge is not possible
    *)
    let rec try_merge_side fbox boxes iy ix mdir =
      let (collapse_mdir, len, iy_ix_list) = match mdir with
        | UD _ ->
          let l = Dim.int_of_boxdim fbox.w in
          List.(LR R, l, map (fun ix -> (iy, ix)) @@ range ix `To (ix + l - 1))
        | LR _ ->
          let l = Dim.int_of_boxdim fbox.h in
          List.(UD D, l, map (fun iy -> (iy, ix)) @@ range iy `To (iy + l - 1))
      in
      let lengths fb md = Tuple2.mapn Dim.int_of_boxdim
        @@ match md with
        | UD _ -> (fb.w, fb.h)
        | LR _ -> (fb.h, fb.w) in
      let rec collapse_side side_len acc =
        function
        | [] -> if side_len = len then Ok acc else Bad ()
        | (iy, ix) :: iyxs ->
          let next = get_parent boxes iy ix in
          let (t, n) = lengths next mdir in
          match acc with
          | None -> (
              (* first box must have the appropriate edge aligned *)
              let aligned = match mdir with
                | UD _ -> next.x = Dim.Boxdim ix
                | LR _ -> next.y = Dim.Boxdim iy in
              if aligned then collapse_side t (Some (n, [next], next)) iyxs
              else Bad ()
            )
          | Some (_, [], _) -> raise (Invalid_argument "collapsing sides")
          | Some (n', fb :: fbs, net) ->
            if flexbox_eq next fb then
              collapse_side side_len (Some (n', fb :: fbs, net)) iyxs
            else
              let side_len = t + side_len in
              if side_len > len || n <> n' then Bad ()
              else
                match merge_pair net next collapse_mdir with
                | Bad () -> Bad ()
                | Ok net ->
                  collapse_side side_len (Some (n, next :: fb :: fbs, net)) iyxs
      in
      match collapse_side 0 None iy_ix_list with
      | Bad ()
      | Ok None -> Bad ()
      | Ok (Some (_, fbs, net)) ->
        match merge_pair fbox net mdir with
        | Bad () -> Bad ()
        | Ok t -> Ok (fbox, fbs, t)

    let in_bounds ~width ~height iy ix = function
      | UD U -> iy >= 0
      | UD D -> iy < height
      | LR L -> ix >= 0
      | LR R -> ix < width

    let next_fbox fbox =
      let (iy, ix) = get_yx fbox in
      function
      | UD U -> (iy - 1, ix)
      | UD D -> (iy + Dim.int_of_boxdim fbox.h, ix)
      | LR L -> (iy, ix - 1)
      | LR R -> (iy, ix + Dim.int_of_boxdim fbox.w)

    let merge_possible ~width ~height boxes iy ix md =
      match read boxes iy ix with
      | Merged _ -> Bad ()
      | Box fbox ->
        let (iy', ix') = next_fbox fbox md in
        if in_bounds ~width ~height iy' ix' md then
          try_merge_side fbox boxes iy' ix' md
        else Bad ()

    let write boxes iy ix a =
      let row = Array.get boxes iy in
      Array.Cap.set row ix a;
      Array.set boxes iy row

    let merge_all boxes_wronly net =
      let (iy', ix') = get_yx net in
      let f boxes_wronly net fb =
        let (iy, ix) = get_yx fb in
        if not (ix = ix' && iy = iy') then
          write boxes_wronly iy ix (Merged (iy', ix'))
      in
      write boxes_wronly iy' ix' (Box net);
      List.iter (f boxes_wronly net)

    let dumb_synchronise ~width ~height boxes fbox =
      let boxes_rdonly = Array.Cap.(read_only % of_array) boxes in
      let iy, ix = get_yx fbox in
      let f dir =
        let (iy', ix') = next_fbox fbox dir in
        if in_bounds ~width ~height iy' ix' dir then
          let neighbour = get_parent boxes_rdonly iy' ix' in
          let (iy', ix') = get_yx neighbour in
          match dir with
          | UD U -> if ix' = ix then
              boxes.(iy').(ix') <- Box {neighbour with d = fbox.u;}
          | UD D -> if ix' = ix then
              boxes.(iy').(ix') <- Box {neighbour with u = fbox.d;}
          | LR R -> if iy' = iy then
              boxes.(iy').(ix') <- Box {neighbour with l = fbox.r;}
          | LR L -> if iy' = iy then
              boxes.(iy').(ix') <- Box {neighbour with r = fbox.l;}
      in
      List.iter f [LR R; LR L; UD U; UD D;]

    (*
       Decides whether a merge should be performed or not in the direction
       given by md, by looking at the cost (energy) difference between the
       initial and final configuration.
    *)
    let to_merge_or_not_to_merge
        ?(costfn = TableauLayout.wh_cost) ?(phi = Utils.golden_ratio)
        w h w' h' md kB temp =
      let (w, h, w', h') = Tuple4.mapn Dim.int_of_codeldim (w, h, w', h') in
      let dc = match md with
        | UD _ -> costfn phi w (h' - h)
        | LR _ -> costfn phi (w' - w) h in
      let c = costfn phi w h +. dc in
      let c' = costfn phi w' h' in
      (* add a small bias for domain formation *)
      let z = (c -. c') /. (kB *. temp) +. 0.5 in
      let eminus =
        if z > 10.0 then exp 10.0
        else if z < -10.0 then exp (-10.0)
        else exp z  (* exp (-ΔE/T) *)
      in
      let p = eminus /. (eminus +. 1.0 /. eminus) in
      Random.float 1.0 < p

    (*
       Creates "domains" out of a uniform mesh as emitted by make_mesh.
       The domain growth probabilities are controlled by two "temperatures"
       for the two directions.
       The result is an array of "stretched" boxes along with arrays for the
       absolute x and y coordinates, including 0 and the max width or height
       (last index)
    *)
    let make_domains ?(tx = 10.0) ?(ty = 10.0) p =
      let width = Dim.Boxdim TG.(p.width + 1) in
      let height = Dim.Boxdim TG.(p.tot_h) in
      let ((tot_w, tot_h), (abs_x_l, abs_y_l)) =
        Rules.simple_grid
          ~aspect:Utils.golden_ratio
          ~nx:Dim.(sub_boxdim width (Boxdim 1))
          ~ny:Dim.(sub_boxdim height (Boxdim 1)) in
      let abs_x_a = Array.of_list @@ Dim.Codeldim 0 :: abs_x_l @ [tot_w] in
      let abs_y_a = Array.of_list @@ Dim.Codeldim 0 :: abs_y_l @ [tot_h] in
      let boxes = Array.(map (map (fun b -> Box b)))
        @@ make_box_array ~width ~height p in
      let area = float Dim.(int_of_codeldim tot_h * int_of_codeldim tot_w) in
      (* Chosen arbitrarily, should be roughly proportional to area *)
      let kB = area /. (1.0 +. log area) in

      let rec f iy ix md =
        let boxes_rdonly = Array.Cap.(boxes |> of_array |> read_only) in
        match merge_possible
                (Dim.int_of_boxdim width) (Dim.int_of_boxdim height)
                boxes_rdonly iy ix md with
        | Bad () -> ()
        | Ok (fbox, fbs, net) ->
          let w, h = get_abs_wh fbox abs_x_a abs_y_a in
          let w', h' = get_abs_wh net abs_x_a abs_y_a in
          let temp = (match md with | UD _ -> ty | LR _ -> tx) in
          if to_merge_or_not_to_merge w h w' h' md kB temp then (
            let boxes_wronly = Array.(map Cap.(write_only % of_array) boxes) in
            merge_all boxes_wronly net (fbox :: fbs);
            let Dim.Boxdim width = width in
            let Dim.Boxdim height = height in
            dumb_synchronise ~width ~height boxes net;
            let (iy', ix') = get_yx net in
            f iy' ix' md;
          )
          else ()
      in
      for iy = 0 to Dim.int_of_boxdim height - 1 do
        for ix = 0 to Dim.int_of_boxdim width - 1 do
          List.iter (fun md -> f iy ix md) [LR R; LR L; UD U; UD D;]
        done
      done;
      ((boxes : domains), (width, height, abs_x_a, abs_y_a))
  end

  module TableauPaint = struct

    let primes = BatSet.of_list [
        2; 3; 5; 7; 11; 13; 17; 19; 23; 29; 31; 37; 41; 43; 47; 53;
        59; 61; 67; 71; 73; 79; 83; 89; 97; 101; 103; 107; 109;
        113; 127; 131; 137; 139; 149; 151; 157; 163; 167; 173;
        179; 181; 191; 193; 197; 199; 211; 223; 227; 229; 233; 239;
        241; 251;
      ]

    let rec factor_pairs n =
      if n < 14 then []
      else if BatSet.mem n primes then
        let s = factor_pairs (n-1) in
        if s = [] then []
        else s
      else
        let phi = Utils.golden_ratio in
        let n_f = float n in
        let golden_d = int_of_float @@ sqrt (n_f /. phi) in
        let delta_d = max 1 @@ int_of_float (sqrt n_f -. sqrt (n_f /. phi)) in
        let l1 = List.fold_left
            (fun l d -> if n mod d = 0 then (d, n / d) :: l else l)
            [] @@ List.range golden_d `To (golden_d + delta_d) in
        let l2 = List.fold_left
            (fun l d -> if n mod d = 0 then (d, n / d) :: l else l)
            [] @@ List.range (golden_d - delta_d) `To (golden_d) in

        (l1 @ l2)
        |> List.sort_uniq
          (fun (d1,d2) (d3,d4) ->
             compare
               (abs_float ((float d2)/.(float d1)) -. phi)
               (abs_float ((float d4)/.(float d3)) -. phi))
        |> List.filter (fun (d1, d2) -> (float d2)/.(float d1) < 21./.9.)

    type ruledir = V | H [@@deriving show]
    type rule = {
      dir       : ruledir;
      top_left  : xy;
      bot_right : xy;
      nonblack  : codel list;
    } [@@deriving show]

    let stick_rule x y w h rel_codels =
      let (x, y, w, h) = Tuple4.mapn Dim.int_of_codeldim (x, y, w, h) in
      let abs_codels = List.map (fun (c, x', y') ->
          Dim.(c, x + int_of_codeldim x', y + int_of_codeldim y')) rel_codels in
      {
        dir = V;
        top_left  = (min x (x + w - 1), min y (y + h - 1));
        bot_right = (max x (x + w - 1), max y (y + h - 1));
        nonblack = abs_codels;
      }

    type turn = CW | ACW
    let reverse = function
      | CW -> ACW
      | ACW -> CW
    let sign = function
      | CW -> 1
      | ACW -> -1

    let codels_of_opv startc turn opv =
      let linew = 1 + V.length opv in
      let pos i = (linew + (i + 1) * sign turn) mod linew in
      let f = fun i a op -> let (c, _, _) = List.hd a in
        Dim.(op_next_colour op c, Codeldim (pos i), Codeldim 0) :: a in
      V.foldi f [Dim.(startc, Codeldim 0, Codeldim 0)] opv

    let thickness l = match l.dir with
      | V -> (fst l.bot_right) - (fst l.top_left)
      | H -> (snd l.bot_right) - (snd l.top_left)
    let length l = match l.dir with
      | V -> (snd l.bot_right) - (snd l.top_left)
      | H -> (fst l.bot_right) - (fst l.top_left)

    type panel = {
      fill      : colour;
      extra     : codel list;
      enter     : xy;
      leave     : xy;
      top_left  : xy;
      bot_right : xy;
      flow      : xy list;
    } [@@deriving show {with_path = false}]

    let white_panel x y w h =
      let (x, y, w, h) = Tuple4.mapn Dim.int_of_codeldim (x, y, w, h) in
      {
        fill = White;
        extra = [];
        enter = (x, y);
        leave = (x + w - 1, y + h - 1);
        top_left = (min x (x + w - 1), min y (y + h - 1));
        bot_right = (max x (x + w - 1), max y (y + h - 1));
        flow = [(x, y); (x + w - 1, y)];
      }

    let filled_panel fill x y w h =
      ({(white_panel x y w h) with fill;},
       (op_prev_colour PPush fill, op_next_colour PPop fill))

    type element = Panel of panel | Rule of rule
    [@@deriving show {with_path = false}]

    let top_left = function
      | Panel p -> p.top_left
      | Rule l -> l.top_left
    let bot_right = function
      | Panel p -> p.bot_right
      | Rule l -> l.bot_right
    let extra = function
      | Panel p -> p.extra
      | Rule l -> l.nonblack
    let fill = function
      | Panel p -> p.fill
      | Rule l -> Black

    (* The turn structures have transitions = J.num_ops + 1 where the +1 is to *)
    (*       redirect the flow with the pointer instruction. *)
    (* let cw_turn = *)
    (*   V.make (J.num_ops - 1) PNop *)
    (*   |> V.prepend @@ PPush *)
    (*   |> V.append @@ PPtr *)
    (* let acw_turn = *)
    (*   V.make 2 PNop *)
    (*   |> V.append PPush *)
    (*   |> fun z -> V.concat z (V.make (J.num_ops - 3) PNop) *)
    (*   |> V.append PPtr *)

    let cw_ptr_clr = LightCyan
    let acw_ptr_clr = LightYellow

    (* let cw_ptr_clr = LightCyan in *)
    (* let cw_ptr_prev_clr = op_prev_colour PPtr cw_ptr_clr in *)
    (* (V.make J.num_ops cw_ptr_prev_clr *)
    (*  |> V.prepend @@ op_prev_colour PPush cw_ptr_prev_clr *)
    (*  |> V.append cw_ptr_clr, *)

    (* let append_vec a1 a2 = V.concat a2 a1 in *)
    (* let acw_ptr_clr = LightYellow in *)
    (* let acw_ptr_prev_clr = op_prev_colour PPtr acw_ptr_clr in *)
    (* (V.make 3 @@ op_prev_colour PPush acw_ptr_prev_clr *)
    (*  |> append_vec @@ V.make (J.num_ops - 2) acw_ptr_prev_clr *)
    (*  |> V.append acw_ptr_prev_clr, *)

    (* module ST = Utils.SplayTree( *)
    (*   struct *)
    (*     type t = element *)
    (*     type s = xy *)
    (*     let t_compare e1 e2 = *)
    (*       let  (xy1, xy2) = (top_left e1, top_left e2) in *)
    (*       compare_xy xy1 xy2 *)
    (*     let s_inside_t pt e = *)
    (*       let (xy1, xy2) = (top_left e, bot_right e) in *)
    (*       match compare_xy pt xy1 with *)
    (*       | Utils.LT -> Utils.LT *)
    (*       | _ -> (match compare_xy pt xy2 with *)
    (*           | Utils.GT -> Utils.GT *)
    (*           | _ -> Utils.EQ) *)
    (*   end) *)

    let rule_w = Dim.(map_codeldim ((+) 1) Rules.num_ops)

    type annot_elem = EOPPanel of panel
                    | FlowPanel of panel
                    | TunnelRule of rule
                    | TurnPanel of panel
                    | TurnRule of rule
                    | DummyPanel of panel
                    | DummyRule of rule

    type abs_dims = {
      abs_x : Dim.codeldim array;
      abs_y : Dim.codeldim array;
      abs_w : Dim.codeldim;
      abs_h : Dim.codeldim;
      total_w : Dim.boxdim;
      total_h : Dim.boxdim;
    }

    module TG = TableauGrid

    type flexbox = TableauDomains.flexbox = {
      x : Dim.boxdim; y : Dim.boxdim;
      w : Dim.boxdim; h : Dim.boxdim;
      u : TG.h_edge; d : TG.h_edge;
      l : TG.v_edge; r : TG.v_edge;
    }

    let start_x ad fb = match Dim.int_of_boxdim fb.x with
      | 0 -> 0
      | i -> Dim.int_of_codeldim ad.abs_x.(i) + J.num_ops + 1

    let start_y ad fb = match Dim.int_of_boxdim fb.y with
      | 0 -> 0
      | i -> Dim.int_of_codeldim ad.abs_y.(i) + J.num_ops + 1

    let stop_x ad fb = match Dim.add_boxdim fb.x fb.w with
      | z when z = ad.total_w -> Dim.int_of_codeldim ad.abs_w - 1
      | Dim.Boxdim i -> Dim.int_of_codeldim ad.abs_x.(i) - 1

    let stop_y ad fb = match Dim.add_boxdim fb.y fb.h with
      | z when z = ad.total_h -> Dim.int_of_codeldim ad.abs_h - 1
      | Dim.Boxdim i -> Dim.int_of_codeldim ad.abs_y.(i) - 1

    let fill_panel abs_dims pic fbox =
      let open TableauDomains in
      let start_x = start_x abs_dims fbox in
      let start_y = start_y abs_dims fbox in
      let stop_x = stop_x abs_dims fbox in
      let stop_y = stop_y abs_dims fbox in
      for iy = start_y to stop_y do
        for ix = start_x to stop_x do
          pic.(iy).(ix) <- Utils.Piet.White
        done
      done

    let start_colour = LightCyan

    let fill_vedge pic (tl_x, tl_y) = function
      | TG.VBoundary ->
        raise (Invalid_argument "Cannot draw vertical boundary.")
      | TG.VEOPTunnel _ ->
        raise (Invalid_argument "EOP tunnels should be handled earlier.")
      | TG.VSolid -> ()
      (* NOTE: Assumes that background is filled black initially. *)
      | TG.VOpTunnel (dir, ops) ->
        let colours =
          let colours = op_next_colours start_colour ops in
          match dir with
          | TG.LtoR -> colours
          | TG.RtoL -> List.rev colours
        in
        List.iteri (fun i c -> pic.(tl_y).(tl_x + i) <- c) colours
      | TG.VNopTunnel -> ()
      | TG.VPreTurnTunnel (rot, pre_sem) -> ()
      | TG.VPostTurnTunnel (dir, post_sem) -> ()

    let fill_hedge pic (tl_x, tl_y) = function
      | TG.HBoundary -> raise (Invalid_argument "Cannot draw horizontal boundary.")
      | TG.HSolid -> ()
      | TG.HNopTunnel lr -> ()
      | TG.HPreTurnTunnel lr -> ()
      | TG.HPostTurnTunnel lr -> ()
      | TG.HPreReentryTunnel lr -> ()
      | TG.HPostTurnPreReentry lr -> ()

    let fill_edges abs_dims pic fbox =
      (* TODO: Clean up this code? *)
      let open TableauDomains in
      let () = match fbox.l with
        | TG.VBoundary -> ()
        | TG.VEOPTunnel TG.RtoL -> ()
        (* do nothing, the EOP panel will take care of this *)
        | TG.VEOPTunnel TG.LtoR ->
          (* TODO: Implement code termination here *)
          ()
        | l ->
          let tl_x = start_x abs_dims fbox - J.num_ops - 1 in
          let tl_y = start_y abs_dims fbox in
          fill_vedge pic (tl_x, tl_y) l
      in
      let () = match fbox.r with
        | TG.VBoundary -> ()
        | TG.VEOPTunnel TG.LtoR ->
          (* TODO: Implement code termination here *)
          ()
        | TG.VEOPTunnel TG.RtoL -> ()
        (* do nothing, the EOP panel will take care of this *)
        | r ->
          let tl_x = stop_x abs_dims fbox + 1 in
          let tl_y = start_y abs_dims fbox in
          fill_vedge pic (tl_x, tl_y) r
      in
      let () = match fbox.u with
        | TG.HBoundary -> ()
        | u ->
          let tl_x = start_x abs_dims fbox in
          let tl_y = start_y abs_dims fbox - J.num_ops - 1 in
          fill_hedge pic (tl_x, tl_y) u in
      let () = match fbox.d with
        | TG.HBoundary -> ()
        | d ->
          let tl_x = start_x abs_dims fbox in
          let tl_y = start_y abs_dims fbox + 1 in
          fill_hedge pic (tl_x, tl_y) d
      in
      ()

    (* TODO: replace this with a nice colouring scheme *)
    let draw_mbox abs_dims pic mbox =
      match mbox with
      | TableauDomains.Merged _ -> ()
      | TableauDomains.Box fbox -> (
          fill_panel abs_dims pic fbox;
          fill_edges abs_dims pic fbox;
        )

    let draw_picture (mboxes, (total_w, total_h, abs_x_a, abs_y_a)) =
      let split_last a =
        let l = Array.length a in
        Array.(sub a 0 (l - 2), get a (l - 1)) in
      let (abs_x, abs_w) = split_last abs_x_a in
      let (abs_y, abs_h) = split_last abs_y_a in
      let abs_dims = {abs_x; abs_w; abs_y; abs_h; total_w; total_h;} in
      let pic = Array.make_matrix
          (Dim.int_of_codeldim abs_h)
          (Dim.int_of_codeldim abs_w)
          Utils.Piet.Black in
      Array.(iter (iter (draw_mbox abs_dims pic)) mboxes)

    (* type composition = ST.t * int * int *)

    (* let composition_of_layout : *)
    (*   annot_elem -> TableauLayout.t -> composition = *)
    (*   let module Tbl = TableauLayout in *)
    (*   fun ps info -> Tbl.(ST.empty, info.width, info.tot_h) *)

    (* let draw_picture : composition -> picture = fun (elem_st, w, h) -> *)
    (*   let set2d x y c a = V.modify a y (fun row -> V.set row x c) in *)
    (*   let elem_vec = ST.to_vec elem_st in *)
    (*   let f array elem = *)
    (*     let (x1, y1) = top_left elem in *)
    (*     let (x2, y2) = bot_right elem in *)
    (*     let codels = extra elem in *)
    (*     List.(range y1 `To y2 *)
    (*           |> fold_left (fun a' y -> *)
    (*               fold_left (fun a'' x -> set2d x y (fill elem) a'') *)
    (*                 a' (range x1 `To x2)) array *)
    (*           |> fun a -> *)
    (*           fold_left (fun a' (c, cx, cy) -> set2d cx cy c a') a codels) *)
    (*   in *)
    (*   let init = V.make h (V.make w Black) in *)
    (*   let pic_arr = V.fold_left f init elem_vec in *)
    (*   (pic_arr, w, h) *)

  end

end

module M = Mondrian(struct
    let num_ops = 5
    let panel_to_rule_size_ratio = 4.0
  end)

let domain_show fpl = IRExpansion.Fast.expand fpl
                      %> M.TableauLayout.ir_mix_list_to_layout
                      %> M.TableauGrid.make_mesh ~random:false
                      %> M.TableauDomains.(make_domains %> fst %> show_domains)

let mesh_show fpl = M.TableauGrid.(show % make_mesh ~random:false)
                    % M.TableauLayout.ir_mix_list_to_layout
                    % IRExpansion.Fast.expand fpl

let tableau_show fpl = M.TableauLayout.(show % ir_mix_list_to_layout)
                       % IRExpansion.Fast.expand fpl

type push_style = Literal
                | Fast of (int * int * Utils.FastPush.push_op list) list
type draw_style = Linear | Tableau

let paint ps ds =
  let expansionfn = IRExpansion.(match ps with
      | Literal -> Naive.expand
      | Fast fpl -> Fast.expand fpl) in
  let drawfn = match ds with
    | Linear -> CanonicalDraw.draw_linear
    | Tableau -> CanonicalDraw.draw_linear in
  drawfn % expansionfn

let interpret = IRExpansion.interpret

module Test = struct
  type t = M.TableauDomains.merged_box

  let domains fpl = IRExpansion.Fast.expand fpl
                    %> M.TableauLayout.ir_mix_list_to_layout
                    %> M.TableauGrid.make_mesh ~random:false
                    %> M.TableauDomains.make_domains %> fst

  let get_wh boxes iy ix =
    let rec f og boxes iy ix =
      match boxes.(iy).(ix), og with
      | M.TableauDomains.Merged (iy', ix'), None -> f (Some (iy, ix)) boxes iy' ix'
      | M.TableauDomains.Merged (iy', ix'), Some _ -> f og boxes iy' ix'
      | M.TableauDomains.Box fb, None ->
        M.TableauDomains.get_wh fb
      | M.TableauDomains.Box fb, Some (og_iy, og_ix) ->
        let (w, h) = M.TableauDomains.get_wh fb in
        let (w, h) =
          if og_iy = iy then (0, h)
          else if og_ix = ix then (w, 0)
          else (0, 0) in
        (w, h) in
    f None boxes iy ix
end
