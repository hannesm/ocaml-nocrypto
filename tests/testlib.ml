open OUnit2

open Nocrypto
open Nocrypto.Uncommon

open Notest


module Fc = struct

  module Rng = struct
    type 'a t = (module Rng.S.N with type t = 'a)
    let int   : int   t = (module Rng.Int)
    let int32 : int32 t = (module Rng.Int32)
    let int64 : int64 t = (module Rng.Int64)
  end

  module Numeric = struct
    type 'a t = (module Numeric.S with type t = 'a)
    let int   : int   t = (module Numeric.Int)
    let int32 : int32 t = (module Numeric.Int32)
    let int64 : int64 t = (module Numeric.Int64)
  end
end

let iter_list xs f = List.iter f xs

let random_is seed = Rng.create ~seed (module Rng.Generators.Null)

let bits64 x =
  Bytes.init 64 @@ fun i ->
    let o = 63 - i in
    if Numeric.Int64.((x lsr o) land 1L = 1L) then '1' else '0'

let vx = Cs.of_hex

let f1_eq ?msg f (a, b) _ =
  assert_cs_equal ?msg (f (vx a)) (vx b)

let f1v_eq ?msg f (aa, b) _ =
  assert_cs_equal ?msg (f (List.map vx aa)) (vx b)

let f2_eq ?msg f (a, b, c) = f1_eq ?msg (f (vx a)) (b, c)

let cases_of f =
  List.map @@ fun params -> test_case (f params)

(* randomized selfies *)

let n_encode_decode_selftest
    (type a) ~typ ~bound (rmod, nmod : a Fc.Rng.t * a Fc.Numeric.t) n =
  let module N = (val nmod) in
  let module R = (val rmod) in
  typ ^ "selftest" >:: times ~n @@ fun _ ->
    let r = R.gen bound in
    let s = N.(of_cstruct_be @@ to_cstruct_be r)
    and t = N.(of_cstruct_be @@ to_cstruct_be ~size:24 r) in
    assert_equal r s;
    assert_equal r t

let n_decode_reencode_selftest (type a) ~typ ~bytes (nmod : a Fc.Numeric.t) n =
  let module N = (val nmod) in
  typ ^ " selftest" >:: times ~n @@ fun _ ->
    let cs  = Rng.generate bytes in
    let cs' = N.(to_cstruct_be ~size:bytes @@ of_cstruct_be cs) in
    assert_cs_equal cs cs'

let random_n_selftest (type a) ~typ (m : a Fc.Rng.t) n (bounds : (a * a) list) =
  let module N = (val m) in
  typ ^ " selftest" >::: (
    bounds |> List.map @@ fun (lo, hi) ->
      "selftest" >:: times ~n @@ fun _ ->
        let x = N.gen_r lo hi in
        if x < lo || x >= hi then assert_failure "range error"
  )

let ecb_selftest (m : (module Cipher_block.S.ECB)) n =
  let module C = ( val m ) in
  "selftest" >:: times ~n @@ fun _ ->
    let data  = Rng.generate (C.block_size * 8)
    and key   = C.of_secret @@ Rng.generate (sample C.key_sizes) in
    let data' =
      C.( data |> encrypt ~key |> encrypt ~key
               |> decrypt ~key |> decrypt ~key ) in
    assert_cs_equal ~msg:"ecb mismatch" data data'

let cbc_selftest (m : (module Cipher_block.S.CBC)) n  =
  let module C = ( val m ) in
  "selftest" >:: times ~n @@ fun _ ->
    let data = Rng.generate (C.block_size * 8)
    and iv   = Rng.generate C.block_size
    and key  = C.of_secret @@ Rng.generate (sample C.key_sizes) in
    assert_cs_equal ~msg:"CBC e->e->d->d" data
      C.( data |> encrypt ~key ~iv |> encrypt ~key ~iv
               |> decrypt ~key ~iv |> decrypt ~key ~iv );
    let (d1, d2) = Cstruct.split data (C.block_size * 4) in
    assert_cs_equal ~msg:"CBC chain"
      C.(encrypt ~key ~iv data)
      C.( let e1 = encrypt ~key ~iv d1 in
          Cstruct.append e1 (encrypt ~key ~iv:(C.next_iv ~iv e1) d2) )

let ctr_selftest (m : (module Cipher_block.S.CTR)) n =
  let module M = (val m) in
  let bs = M.block_size in
  "selftest" >:: times ~n @@ fun _ ->
    let key  = M.of_secret @@ Rng.generate (sample M.key_sizes)
    and ctr  = Rng.generate bs |> M.C.of_cstruct
    and data = Rng.(generate @@ bs + Int.gen (20 * bs)) in
    let enc = M.encrypt ~key ~ctr data in
    let dec = M.decrypt ~key ~ctr enc in
    assert_cs_equal ~msg:"CTR e->d" data dec;
    let (d1, d2) =
      Cstruct.split data @@ bs * Rng.Int.gen (Cstruct.len data / bs) in
    assert_cs_equal ~msg:"CTR chain" enc @@
      Cstruct.append (M.encrypt ~key ~ctr d1)
                     (M.encrypt ~key ~ctr:(M.next_ctr ~ctr d1) d2)

let ctr_offsets (m : (module Cipher_block.S.CTR)) n =
  let module M = (val m) in
  "offsets" >:: fun _ ->
    let key = M.of_secret @@ Rng.generate M.key_sizes.(0) in
    for i = 0 to n - 1 do
      let ctr = match i with
        | 0 -> M.C.(add zero (-1L))
        | _ -> Rng.generate M.block_size |> M.C.of_cstruct
      and gap = Rng.Int.gen 64 in
      let s1 = M.stream ~key ~ctr ((gap + 1) * M.block_size)
      and s2 = M.stream ~key ~ctr:(M.C.add ctr (Int64.of_int gap)) M.block_size in
      assert_cs_equal ~msg:"shifted stream"
        Cstruct.(sub s1 (gap * M.block_size) M.block_size) s2
    done

let xor_selftest n =
  "selftest" >:: times ~n @@ fun _ ->

    let n         = Rng.Int.gen 30 in
    let (a, b, c) = Rng.(generate n, generate n, generate n) in

    let abc  = Cs.(xor (xor a b) c)
    and abc' = Cs.(xor a (xor b c)) in
    let a1   = Cs.(xor abc (xor b c))
    and a2   = Cs.(xor (xor c b) abc) in

    assert_cs_equal ~msg:"assoc" abc abc' ;
    assert_cs_equal ~msg:"invert" a a1 ;
    assert_cs_equal ~msg:"commut" a1 a2

let b64_selftest n =
  "selftest" >:: times ~n @@ fun _ ->
    let n   = Rng.Int.gen 1024 in
    let x   = Rng.generate n in

    let enc = Base64.encode x in
    match Base64.decode enc with
    | Some dec -> assert_cs_equal ~msg:"b64 mismatch" dec x
    | None -> assert_failure "couldn't decode b64"


(* Xor *)

let xor_cases =
  cases_of (f2_eq ~msg:"xor" Cs.xor) [
    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c" ,
    "0c 0b 0a 09 08 07 06 05 04 03 02 01 00" ,
    "0c 0a 08 0a 0c 02 00 02 0c 0a 08 0a 0c" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f" ,
    "0f 0e 0d 0c 0b 0a 09 08 07 06 05 04 03 02 01 00" ,
    "0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f" ;

    "00 01 02", "00", "00" ;

    "00", "00 01 02", "00" ;
  ]

(* B64 *)

let b64_enc_cases =
  cases_of (f1_eq ~msg:"b64" Base64.encode) [
    "66 6f 6f", "5a 6d 39 76" ;
    "66 6f 6f 6f", "5a 6d 39 76 62 77 3d 3d" ;
    "66 6f 6f 6f 6f", "5a 6d 39 76 62 32 38 3d" ;
    "66 6f 6f 6f 6f 6f", "5a 6d 39 76 62 32 39 76" ;
  ]


let f1_opt_eq ?msg f (a, b) _ =
  let maybe = function None -> None | Some h -> Some (vx h) in
  let (a, b) = vx a, maybe b in
  let eq_opt eq a b = match (a, b) with
    | (Some x, Some y) -> eq x y
    | (None  , None  ) -> true
    | _                -> false
  in
  assert_equal b (f a) ?msg
    ~cmp:(eq_opt Cstruct.equal)
    ~pp_diff:(pp_diff (pp_opt xd))

let b64_dec_cases =
  cases_of (f1_opt_eq ~msg:"b64" Base64.decode) [
    "00 5a 6d 39 76", None ;
    "5a 6d 39 76", Some "66 6f 6f" ;
    "5a 6d 39 76 76", None ;
    "5a 6d 39 76 76 76", None ;
    "5a 6d 39 76 76 76 76", None ;
    "5a 6d 39 76 00", None ;
    "5a 6d 39 76 62 77 3d 3d", Some "66 6f 6f 6f" ;
    "5a 6d 39 76 62 77 3d 3d 00", None ;
    "5a 6d 39 76 62 77 3d 3d 00 01", None ;
    "5a 6d 39 76 62 77 3d 3d 00 01 02", None ;
    "5a 6d 39 76 62 77 3d 3d 00 01 02 03", None ;
    "5a 6d 39 76 62 32 38 3d", Some "66 6f 6f 6f 6f" ;
    "5a 6d 39 76 62 32 39 76", Some "66 6f 6f 6f 6f 6f" ;
  ]


let f1_blk_eq ?msg ?(n=1) f (x, y) _ =
  let xs = blocks_of_cs n (vx x) in
  assert_cs_equal ?msg (f (iter_list xs)) (vx y)

let hash_cases (m : (module Hash.S)) ~hash =
  let module H = ( val m ) in
  [ "digest"  >::: cases_of (f1_eq H.digest) hash ;
    "digesti" >::: cases_of (f1_blk_eq H.digesti) hash ;
  ]

let hash_cases_mac (m : (module Hash.S)) ~hash ~mac =
  let module H = ( val m ) in
  [ "digest"  >::: cases_of (f1_eq H.digest) hash ;
    "digesti" >::: cases_of (f1_blk_eq H.digesti) hash ;
    "hmac"    >::: cases_of (f2_eq (fun key -> H.hmac ~key)) mac ;
  ]

(* MD5 *)

let md5_cases =
  hash_cases_mac ( module Hash.MD5 )
  ~hash:[
    "" ,
    "d4 1d 8c d9 8f 00 b2 04 e9 80 09 98 ec f8 42 7e" ;

    "00",
    "93 b8 85 ad fe 0d a0 89 cd f6 34 90 4f d5 9f 71" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f" ,
    "1a c1 ef 01 e9 6c af 1b e0 d3 29 33 1a 4f c2 a8" ;
  ]
  ~mac:[
    "2c 03 ca 51 71 a3 d2 d1 41 71 79 6f c8 b2 6c 54" ,
    "8b bb 87 f4 76 4f ba 6a 55 61 c9 80 d5 35 58 4f
     0a 96 cb 60 49 2b 6e dd 71 a1 1e e5 7a 78 9b 73" ,
    "05 8b 08 41 09 79 8b 56 3d 81 49 1f 5f 82 5b ba" ;

    "2c 03 ca 51 71 a3 d2 d1 41 71 79 6f c8 b2 6c 54
     f0 0d a1 07 6c c9 e4 1f b2 17 ec ad 88 56 a2 6e
     d7 83 c3 3d 85 99 0d 8d c5 8d 03 50 00 e2 6e 80
     0c b5 9a 00 26 fd 15 fd 4c e1 84 9d a5 c6 fa a8
     f7 ef f6 c8 76 73 a3 47 0a d5 5a 5b 56 49 22 ec" ,
    "8b bb 87 f4 76 4f ba 6a 55 61 c9 80 d5 35 58 4f
     0a 96 cb 60 49 2b 6e dd 71 a1 1e e5 7a 78 9b 73" ,
    "61 ac 5c 29 9f e2 18 95 d5 4b eb ff 60 42 91 df" ;

    "2c 03 ca 51 71 a3 d2 d1 41 71 79 6f c8 b2 6c 54
     f0 0d a1 07 6c c9 e4 1f b2 17 ec ad 88 56 a2 6e
     d7 83 c3 3d 85 99 0d 8d c5 8d 03 50 00 e2 6e 80
     0c b5 9a 00 26 fd 15 fd 4c e1 84 9d a5 c6 fa a8" ,
    "8b bb 87 f4 76 4f ba 6a 55 61 c9 80 d5 35 58 4f
     0a 96 cb 60 49 2b 6e dd 71 a1 1e e5 7a 78 9b 73" ,
    "ce 44 c2 a1 c5 46 a7 08 a4 0a 7c f2 5e af b1 33" ;
  ]

(* SHA *)

let sha1_cases =
  hash_cases_mac ( module Hash.SHA1 )
  ~hash:[
    "" ,
    "da 39 a3 ee 5e 6b 4b 0d 32 55 bf ef 95 60 18 90
     af d8 07 09" ;

    "00" ,
    "5b a9 3c 9d b0 cf f9 3f 52 b5 21 d7 42 0e 43 f6
     ed a2 78 4f" ;

    "89 d1 68 64 8d 06 0c f2 ed a1 9a a3 10 56 85 48
     69 84 63 df 13 7c 96 5e b5 7b 23 ec b1 f8 e9 ef" ,
    "00 6f 23 b3 5d 7d 09 78 03 35 68 97 ea 6e e3 3c
     57 b2 11 ca" ;
  ]
  ~mac:[
    "", "",
    "fb db 1d 1b 18 aa 6c 08 32 4b 7d 64 b7 1f b7 63
     70 69 0e 1d" ;

    "9c 64 fc 6a 9a bb 1e 04 43 6d 58 49 3f 0d 30 21
     d6 8f eb a9 67 c0 1f 9f c9 35 dc a5 95 9b 6c 07
     4b 09 c0 39 bb c6 dc da 97 aa c8 ea 88 4e 17 e9
     7c c6 d9 f7 73 70 e0 cb 1d 64 de 6d 57 91 31 b3" ,
    "",
    "f9 b1 39 0f 1d 88 09 1b 1d a4 4a d5 d6 33 28 65
     c2 70 ca da";

    "9c 64 fc 6a 9a bb 1e 04 43 6d 58 49 3f 0d 30 21
     d6 8f eb a9 67 c0 1f 9f c9 35 dc a5 95 9b 6c 07
     4b 09 c0 39 bb c6 dc da 97 aa c8 ea 88 4e 17 e9
     7c c6 d9 f7 73 70 e0 cb 1d 64 de 6d 57 91 31 b3" ,
    "0d 83 e2 e9 b3 98 e2 8b ea e0 59 7f 37 15 95 1a
     4b 4c 3c ce 4b de 15 4f 53 da fb 2f b4 9f 03 ea" ,
    "ca 02 cd 56 77 dc b5 c1 3e de da 34 51 d9 e2 5c
     d9 29 4c 53" ;

    "9c 64 fc 6a 9a bb 1e 04 43 6d 58 49 3f 0d 30 21
     d6 8f eb a9 67 c0 1f 9f c9 35 dc a5 95 9b 6c 07
     4b 09 c0 39 bb c6 dc da 97 aa c8 ea 88 4e 17 e9
     7c c6 d9 f7 73 70 e0 cb 1d 64 de 6d 57 91 31 b3
     8e 17 5f 4e de 38 f4 14 48 bc 74 56 05 7a 3c 3b" ,
    "0d 83 e2 e9 b3 98 e2 8b ea e0 59 7f 37 15 95 1a
     4b 4c 3c ce 4b de 15 4f 53 da fb 2f b4 9f 03 ea" ,
    "7f f9 d5 9e 62 e8 d7 13 91 9f a2 a7 be 64 85 c5
     a0 39 ec 04";
  ]

let sha224_cases =
  hash_cases (module Hash.SHA224)
  ~hash:[
    "" ,
    "d1 4a 02 8c 2a 3a 2b c9 47 61 02 bb 28 82 34 c4
     15 a2 b0 1f 82 8e a6 2a c5 b3 e4 2f" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f" ,
    "52 9d 65 6a 8b c4 13 fe f5 8d a8 2e 1b f0 30 8d
     cf e0 42 9d cd 80 68 7e 69 c9 46 33" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f
     10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f
     20 21 22 23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f
     30 31 32 33 34 35 36 37 38 39 3a 3b 3c 3d 3e 3f",
    "c3 7b 88 a3 52 2d bf 7a c3 0d 1c 68 ea 39 7a c1
     1d 47 73 57 1a ed 01 dd ab 73 53 1e" ;
  ]

let sha256_cases =
  hash_cases (module Hash.SHA256)
  ~hash:[
    "" ,
    "e3 b0 c4 42 98 fc 1c 14 9a fb f4 c8 99 6f b9 24
     27 ae 41 e4 64 9b 93 4c a4 95 99 1b 78 52 b8 55" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f" ,
    "be 45 cb 26 05 bf 36 be bd e6 84 84 1a 28 f0 fd
     43 c6 98 50 a3 dc e5 fe db a6 99 28 ee 3a 89 91" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f
     10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f
     20 21 22 23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f
     30 31 32 33 34 35 36 37 38 39 3a 3b 3c 3d 3e 3f",
    "fd ea b9 ac f3 71 03 62 bd 26 58 cd c9 a2 9e 8f
     9c 75 7f cf 98 11 60 3a 8c 44 7c d1 d9 15 11 08"
  ]

let sha384_cases =
  hash_cases (module Hash.SHA384)
  ~hash:[
    "" ,
    "38 b0 60 a7 51 ac 96 38 4c d9 32 7e b1 b1 e3 6a
     21 fd b7 11 14 be 07 43 4c 0c c7 bf 63 f6 e1 da
     27 4e de bf e7 6f 65 fb d5 1a d2 f1 48 98 b9 5b" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f" ,
    "c8 1d f9 8d 9e 6d e9 b8 58 a1 e6 eb a0 f1 a3 a3
     99 d9 8c 44 1e 67 e1 06 26 01 80 64 85 bb 89 12
     5e fd 54 cc 78 df 5f bc ea bc 93 cd 7c 7b a1 3b" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f
     10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f
     20 21 22 23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f
     30 31 32 33 34 35 36 37 38 39 3a 3b 3c 3d 3e 3f
     40 41 42 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f
     50 51 52 53 54 55 56 57 58 59 5a 5b 5c 5d 5e 5f
     60 61 62 63 64 65 66 67 68 69 6a 6b 6c 6d 6e 6f
     70 71 72 73 74 75 76 77 78 79 7a 7b 7c 7d 7e 7f" ,
    "ca 23 85 77 33 19 12 45 34 11 1a 36 d0 58 1f c3
     f0 08 15 e9 07 03 4b 90 cf f9 c3 a8 61 e1 26 a7
     41 d5 df cf f6 5a 41 7b 6d 72 96 86 3a c0 ec 17"
  ]


let sha512_cases =
  hash_cases (module Hash.SHA512)
  ~hash:[
    "" ,
    "cf 83 e1 35 7e ef b8 bd f1 54 28 50 d6 6d 80 07
     d6 20 e4 05 0b 57 15 dc 83 f4 a9 21 d3 6c e9 ce
     47 d0 d1 3c 5d 85 f2 b0 ff 83 18 d2 87 7e ec 2f
     63 b9 31 bd 47 41 7a 81 a5 38 32 7a f9 27 da 3e" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f" ,
    "da a2 95 be ed 4e 2e e9 4c 24 01 5b 56 af 62 6b
     4f 21 ef 9f 44 f2 b3 d4 0f c4 1c 90 90 0a 6b f1
     b4 86 7c 43 c5 7c da 54 d1 b6 fd 48 69 b3 f2 3c
     ed 5e 0b a3 c0 5d 0b 16 80 df 4e c7 d0 76 24 03" ;

    "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f
     10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f
     20 21 22 23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f
     30 31 32 33 34 35 36 37 38 39 3a 3b 3c 3d 3e 3f
     40 41 42 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f
     50 51 52 53 54 55 56 57 58 59 5a 5b 5c 5d 5e 5f
     60 61 62 63 64 65 66 67 68 69 6a 6b 6c 6d 6e 6f
     70 71 72 73 74 75 76 77 78 79 7a 7b 7c 7d 7e 7f" ,
    "1d ff d5 e3 ad b7 1d 45 d2 24 59 39 66 55 21 ae
     00 1a 31 7a 03 72 0a 45 73 2b a1 90 0c a3 b8 35
     1f c5 c9 b4 ca 51 3e ba 6f 80 bc 7b 1d 1f da d4
     ab d1 34 91 cb 82 4d 61 b0 8d 8c 0e 15 61 b3 f7" ;
  ]

let sha2_cases = [
  "sha224" >::: sha224_cases ;
  "sha256" >::: sha256_cases ;
  "sha384" >::: sha384_cases ;
  "sha512" >::: sha512_cases ;
]

(* NIST SP 800-38A test vectors for block cipher modes of operation *)

let nist_sp_800_38a = vx
  "6b c1 be e2 2e 40 9f 96 e9 3d 7e 11 73 93 17 2a
   ae 2d 8a 57 1e 03 ac 9c 9e b7 6f ac 45 af 8e 51
   30 c8 1c 46 a3 5c e4 11 e5 fb c1 19 1a 0a 52 ef
   f6 9f 24 45 df 4f 9b 17 ad 2b 41 7b e6 6c 37 10"

let aes_ecb_cases =
  let open Cipher_block in

  let case ~key ~out = (AES.ECB.of_secret (vx key), vx out)

  and check (key, out) _ =
    let enc = AES.ECB.encrypt ~key nist_sp_800_38a in
    let dec = AES.ECB.decrypt ~key enc in
    assert_cs_equal ~msg:"ciphertext" out enc ;
    assert_cs_equal ~msg:"plaintext" nist_sp_800_38a dec in

  cases_of check [
    case ~key: "2b 7e 15 16 28 ae d2 a6 ab f7 15 88 09 cf 4f 3c"
         ~out: "3a d7 7b b4 0d 7a 36 60 a8 9e ca f3 24 66 ef 97
                f5 d3 d5 85 03 b9 69 9d e7 85 89 5a 96 fd ba af
                43 b1 cd 7f 59 8e ce 23 88 1b 00 e3 ed 03 06 88
                7b 0c 78 5e 27 e8 ad 3f 82 23 20 71 04 72 5d d4"

  ; case ~key: "8e 73 b0 f7 da 0e 64 52 c8 10 f3 2b 80 90 79 e5
                62 f8 ea d2 52 2c 6b 7b"
         ~out: "bd 33 4f 1d 6e 45 f2 5f f7 12 a2 14 57 1f a5 cc
                97 41 04 84 6d 0a d3 ad 77 34 ec b3 ec ee 4e ef
                ef 7a fd 22 70 e2 e6 0a dc e0 ba 2f ac e6 44 4e
                9a 4b 41 ba 73 8d 6c 72 fb 16 69 16 03 c1 8e 0e"

  ; case ~key: "60 3d eb 10 15 ca 71 be 2b 73 ae f0 85 7d 77 81
                1f 35 2c 07 3b 61 08 d7 2d 98 10 a3 09 14 df f4"
         ~out: "f3 ee d1 bd b5 d2 a0 3c 06 4b 5a 7e 3d b1 81 f8
                59 1c cb 10 d4 10 ed 26 dc 5b a7 4a 31 36 28 70
                b6 ed 21 b9 9c a6 f4 f9 f1 53 e7 b1 be af ed 1d
                23 30 4b 7a 39 f9 f3 ff 06 7d 8d 8f 9e 24 ec c7"
  ]

let aes_cbc_cases =
  let open Cipher_block in

  let case ~key ~iv ~out = (AES.CBC.of_secret (vx key), vx iv, vx out)

  and check (key, iv, out) _ =
    let enc = AES.CBC.encrypt ~key ~iv nist_sp_800_38a in
    let dec = AES.CBC.decrypt ~key ~iv enc in
    assert_cs_equal ~msg:"ciphertext" out enc ;
    assert_cs_equal ~msg:"plaintext" nist_sp_800_38a dec in

  cases_of check [
    case ~key: "2b 7e 15 16 28 ae d2 a6 ab f7 15 88 09 cf 4f 3c"
         ~iv:  "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f"
         ~out: "76 49 ab ac 81 19 b2 46 ce e9 8e 9b 12 e9 19 7d
                50 86 cb 9b 50 72 19 ee 95 db 11 3a 91 76 78 b2
                73 be d6 b8 e3 c1 74 3b 71 16 e6 9e 22 22 95 16
                3f f1 ca a1 68 1f ac 09 12 0e ca 30 75 86 e1 a7"

  ; case ~key: "8e 73 b0 f7 da 0e 64 52 c8 10 f3 2b 80 90 79 e5
                62 f8 ea d2 52 2c 6b 7b"
         ~iv:  "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f"
         ~out: "4f 02 1d b2 43 bc 63 3d 71 78 18 3a 9f a0 71 e8
                b4 d9 ad a9 ad 7d ed f4 e5 e7 38 76 3f 69 14 5a
                57 1b 24 20 12 fb 7a e0 7f a9 ba ac 3d f1 02 e0
                08 b0 e2 79 88 59 88 81 d9 20 a9 e6 4f 56 15 cd"

  ; case ~key: "60 3d eb 10 15 ca 71 be 2b 73 ae f0 85 7d 77 81
                1f 35 2c 07 3b 61 08 d7 2d 98 10 a3 09 14 df f4"
         ~iv:  "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f"
         ~out: "f5 8c 4c 04 d6 e5 f1 ba 77 9e ab fb 5f 7b fb d6
                9c fc 4e 96 7e db 80 8d 67 9f 77 7b c6 70 2c 7d
                39 f2 33 69 a9 d9 ba cf a5 30 e2 63 04 23 14 61
                b2 eb 05 e2 c3 9b e9 fc da 6c 19 07 8c 6a 9d 1b"
  ]

let aes_ctr_cases =
  let case ~key ~ctr ~out ~ctr1 = test_case @@ fun _ ->
    let open Cipher_block.AES.CTR in
    let key  = vx key |> of_secret
    and ctr  = vx ctr |> C.of_cstruct
    and ctr1 = vx ctr1 |> C.of_cstruct
    and out  = vx out in
    let enc = encrypt ~key ~ctr nist_sp_800_38a in
    let dec = decrypt ~key ~ctr enc in
    assert_cs_equal ~msg:"cipher" out enc;
    assert_cs_equal ~msg:"plain" nist_sp_800_38a dec;
    let blocks = Cstruct.len nist_sp_800_38a / block_size in
    assert_equal ~msg:"counters" ctr1 (C.add ctr (Int64.of_int blocks))
      ~pp_diff:(pp_map xd C.to_cstruct |> pp_diff)
  in
  [ case ~key:  "2b7e1516 28aed2a6 abf71588 09cf4f3c"
         ~ctr:  "f0f1f2f3 f4f5f6f7 f8f9fafb fcfdfeff"
         ~out:  "874d6191 b620e326 1bef6864 990db6ce
                 9806f66b 7970fdff 8617187b b9fffdff
                 5ae4df3e dbd5d35e 5b4f0902 0db03eab
                 1e031dda 2fbe03d1 792170a0 f3009cee"
         ~ctr1: "f0f1f2f3 f4f5f6f7 f8f9fafb fcfdff03"

  ; case ~key:  "8e73b0f7 da0e6452 c810f32b 809079e5
                 62f8ead2 522c6b7b"
         ~ctr:  "f0f1f2f3 f4f5f6f7 f8f9fafb fcfdfeff"
         ~out:  "1abc9324 17521ca2 4f2b0459 fe7e6e0b
                 090339ec 0aa6faef d5ccc2c6 f4ce8e94
                 1e36b26b d1ebc670 d1bd1d66 5620abf7
                 4f78a7f6 d2980958 5a97daec 58c6b050"
         ~ctr1: "f0f1f2f3 f4f5f6f7 f8f9fafb fcfdff03"

  ; case ~key:  "603deb10 15ca71be 2b73aef0 857d7781
                 1f352c07 3b6108d7 2d9810a3 0914dff4"
         ~ctr:  "f0f1f2f3 f4f5f6f7 f8f9fafb fcfdfeff"
         ~out:  "601ec313 775789a5 b7a7f504 bbf3d228
                 f443e3ca 4d62b59a ca84e990 cacaf5c5
                 2b0930da a23de94c e87017ba 2d84988d
                 dfc9c58d b67aada6 13c2dd08 457941a6"
         ~ctr1: "f0f1f2f3 f4f5f6f7 f8f9fafb fcfdff03"

  ; case ~key:  "00010203 04050607 08090a0b 0c0d0e0f" (* ctr rollover *)
         ~ctr:  "00000000 00000000 ffffffff fffffffe"
         ~out:  "5d0a5645 378f579a 988ff186 d42eaa2f
                 978a655d 145bfe34 21656c8f 01101a43
                 23d0862c 47f7e3bf 95586ba4 2ab4cb31
                 790b0d01 93c0d022 3469534e 537ce82d"
         ~ctr1: "00000000 00000001 00000000 00000002"
  ]

(* aes gcm *)

let gcm_cases =
  let open Cipher_block in

  let case ~key ~p ~a ~iv ~c ~t =
    (AES.GCM.of_secret (vx key), vx p, vx a, vx iv, vx c, vx t) in

  let check (key, p, adata, iv, c, t) _ =
    let open AES.GCM in
    let { message = cdata ; tag = ctag } =
      AES.GCM.encrypt ~key ~iv ~adata p in
    let { message = pdata ; tag = ptag } =
      AES.GCM.decrypt ~key ~iv ~adata cdata
    in
    assert_cs_equal ~msg:"ciphertext" c cdata ;
    assert_cs_equal ~msg:"encryption tag" t ctag  ;
    assert_cs_equal ~msg:"decrypted plaintext" p pdata ;
    assert_cs_equal ~msg:"decryption tag" t ptag
  in

  cases_of check [

    case ~key: "00000000000000000000000000000000"
         ~p:   ""
         ~a:   ""
         ~iv:  "000000000000000000000000"
         ~c:   ""
         ~t:   "58e2fccefa7e3061367f1d57a4e7455a" ;
    case ~key: "00000000000000000000000000000000"
         ~p:   "00000000000000000000000000000000"
         ~a:   ""
         ~iv:  "000000000000000000000000"
         ~c:   "0388dace60b6a392f328c2b971b2fe78"
         ~t:   "ab6e47d42cec13bdf53a67b21257bddf" ;
    case ~key: "feffe9928665731c6d6a8f9467308308"
         ~p:   "d9313225f88406e5a55909c5aff5269a
                86a7a9531534f7da2e4c303d8a318a72
                1c3c0c95956809532fcf0e2449a6b525
                b16aedf5aa0de657ba637b391aafd255"
         ~a:   ""
         ~iv:  "cafebabefacedbaddecaf888"
         ~c:   "42831ec2217774244b7221b784d0d49c
                e3aa212f2c02a4e035c17e2329aca12e
                21d514b25466931c7d8f6a5aac84aa05
                1ba30b396a0aac973d58e091473f5985"
         ~t:   "4d5c2af327cd64a62cf35abd2ba6fab4" ;
    case ~key: "feffe9928665731c6d6a8f9467308308"
         ~p:   "d9313225f88406e5a55909c5aff5269a
                86a7a9531534f7da2e4c303d8a318a72
                1c3c0c95956809532fcf0e2449a6b525
                b16aedf5aa0de657ba637b39"
         ~a:   "feedfacedeadbeeffeedfacedeadbeef
                abaddad2"
         ~iv:  "cafebabefacedbaddecaf888"
         ~c:   "42831ec2217774244b7221b784d0d49c
                e3aa212f2c02a4e035c17e2329aca12e
                21d514b25466931c7d8f6a5aac84aa05
                1ba30b396a0aac973d58e091"
         ~t:   "5bc94fbc3221a5db94fae95ae7121a47" ;
    case ~key: "feffe9928665731c6d6a8f9467308308"
         ~p:   "d9313225f88406e5a55909c5aff5269a
                86a7a9531534f7da2e4c303d8a318a72
                1c3c0c95956809532fcf0e2449a6b525
                b16aedf5aa0de657ba637b39"
         ~a:   "feedfacedeadbeeffeedfacedeadbeef
                abaddad2"
         ~iv:  "cafebabefacedbad"
         ~c:   "61353b4c2806934a777ff51fa22a4755
                699b2a714fcdc6f83766e5f97b6c7423
                73806900e49f24b22b097544d4896b42
                4989b5e1ebac0f07c23f4598"
         ~t:   "3612d2e79e3b0785561be14aaca2fccb" ;
    case ~key: "feffe9928665731c6d6a8f9467308308"
         ~p:   "d9313225f88406e5a55909c5aff5269a
                86a7a9531534f7da2e4c303d8a318a72
                1c3c0c95956809532fcf0e2449a6b525
                b16aedf5aa0de657ba637b39"
         ~a:   "feedfacedeadbeeffeedfacedeadbeef
                abaddad2"
         ~iv:  "9313225df88406e555909c5aff5269aa
                6a7a9538534f7da1e4c303d2a318a728
                c3c0c95156809539fcf0e2429a6b5254
                16aedbf5a0de6a57a637b39b"
         ~c:   "8ce24998625615b603a033aca13fb894
                be9112a5c3a211a8ba262a3cca7e2ca7
                01e4a9a4fba43c90ccdcb281d48c7c6f
                d62875d2aca417034c34aee5"
         ~t:   "619cc5aefffe0bfa462af43c1699d050" ;
    case ~key: "feffe9928665731c6d6a8f9467308308
                feffe9928665731c"
         ~p:   "d9313225f88406e5a55909c5aff5269a
                86a7a9531534f7da2e4c303d8a318a72
                1c3c0c95956809532fcf0e2449a6b525
                b16aedf5aa0de657ba637b39"
         ~a:   "feedfacedeadbeeffeedfacedeadbeef
                abaddad2"
         ~iv:  "cafebabefacedbaddecaf888"
         ~c:   "3980ca0b3c00e841eb06fac4872a2757
                859e1ceaa6efd984628593b40ca1e19c
                7d773d00c144c525ac619d18c84a3f47
                18e2448b2fe324d9ccda2710"
         ~t:   "2519498e80f1478f37ba55bd6d27618c" ;
    case ~key: "feffe9928665731c6d6a8f9467308308
                feffe9928665731c6d6a8f9467308308"
         ~p:   "d9313225f88406e5a55909c5aff5269a
                86a7a9531534f7da2e4c303d8a318a72
                1c3c0c95956809532fcf0e2449a6b525
                b16aedf5aa0de657ba637b39"
         ~a:   "feedfacedeadbeeffeedfacedeadbeef
                abaddad2"
         ~iv:  "9313225df88406e555909c5aff5269aa
                6a7a9538534f7da1e4c303d2a318a728
                c3c0c95156809539fcf0e2429a6b5254
                16aedbf5a0de6a57a637b39b"
         ~c:   "5a8def2f0c9e53f1f75d7853659e2a20
                eeb2b22aafde6419a058ab4f6f746bf4
                0fc0c3b780f244452da3ebf1c5d82cde
                a2418997200ef82e44ae7e3f"
         ~t:   "a44a8266ee1c8eb0c8b5d4cf5ae9f19a";
    case ~key: "00000000000000000000000000000000"  (* large GHASH batch *)
         ~p:   ""
         ~a:   "f0f0f0f0f0f0f0f00f0f0f0f0f0f0f0f
                e0e0e0e0e0e0e0e00e0e0e0e0e0e0e0e
                d0d0d0d0d0d0d0d00d0d0d0d0d0d0d0d
                c0c0c0c0c0c0c0c00c0c0c0c0c0c0c0c
                b0b0b0b0b0b0b0b00b0b0b0b0b0b0b0b
                a0a0a0a0a0a0a0a00a0a0a0a0a0a0a0a
                90909090909090900909090909090909
                80808080808080800808080808080808
                70707070707070700707070707070707
                60606060606060600606060606060606
                50505050505050500505050505050505
                40404040404040400404040404040404
                30303030303030300303030303030303
                20202020202020200202020202020202
                10101010101010100101010101010101
                00000000000000000000000000000000
                ff"
         ~iv:  "000000000000000000000000"
         ~c:   ""
         ~t:   "9bfdb8fdac1be65739780c41703c0fb6";
    case ~key: "00000000000000000000000000000002"  (* ctr rollover *)
         ~iv:  "3222415d"
         ~p:   "deadbeefdeadbeefdeadbeefdeadbeef
                deadbeefdeadbeefdeadbeefdeadbeef
                deadbeef"
         ~a:   ""
         ~c:   "42627ce3de61b5c105c7f01629c031c1
                b890bb273b6b6bc26b56c801f87fa95c
                a8b37503"
         ~t:   "3631cbe44782713b93b1c7d93c3c8638"
]


(* from SP800-38C_updated-July20_2007.pdf appendix C *)
let ccm_cases =
  let open Cipher_block.AES.CCM in
  let case ~key ~p ~a ~nonce ~c ~maclen =
    (of_secret ~maclen (vx key), vx p, vx a, vx nonce, vx c) in

  let check (key, p, adata, nonce, c) _ =
    let cip = encrypt ~key ~nonce ~adata p in
    assert_cs_equal ~msg:"encrypt" c cip ;
    match decrypt ~key ~nonce ~adata c with
      | Some x -> assert_cs_equal ~msg:"decrypt" p x
      | None -> assert_failure "decryption broken"
  in

  cases_of check [

    case ~key:    "404142434445464748494a4b4c4d4e4f"
         ~p:      "20212223"
         ~a:      "0001020304050607"
         ~nonce:  "10111213141516"
         ~c:      "7162015b4dac255d"
         ~maclen: 4
    ;
    case ~key:    "40414243 44454647 48494a4b 4c4d4e4f"
         ~p:      "20212223 24252627 28292a2b 2c2d2e2f"
         ~a:      "00010203 04050607 08090a0b 0c0d0e0f"
         ~nonce:  "10111213 14151617"
         ~c:      "d2a1f0e0 51ea5f62 081a7792 073d593d 1fc64fbf accd"
         ~maclen: 6
    ;
    case ~key:    "404142434445464748494a4b4c4d4e4f"
         ~p:      "202122232425262728292a2b2c2d2e2f3031323334353637"
         ~a:      "000102030405060708090a0b0c0d0e0f10111213"
         ~nonce:  "101112131415161718191a1b"
         ~c:      "e3b201a9f5b71a7a9b1ceaeccd97e70b6176aad9a4428aa5484392fbc1b09951"
         ~maclen: 8
  ]

let int_safe_bytes = Sys.word_size // 8 - 1

let suite =

  "All" >::: [

    "Numeric extraction 1" >::: [
      n_encode_decode_selftest
        ~typ:"int"   ~bound:max_int (Fc.Rng.int, Fc.Numeric.int) 2000 ;
      n_encode_decode_selftest
        ~typ:"int32" ~bound:Int32.max_int (Fc.Rng.int32, Fc.Numeric.int32) 2000 ;
      n_encode_decode_selftest
        ~typ:"int64" ~bound:Int64.max_int (Fc.Rng.int64, Fc.Numeric.int64) 2000 ;
    ] ;

    "Numeric extraction 2" >::: [
      n_decode_reencode_selftest ~typ:"int"   ~bytes:int_safe_bytes Fc.Numeric.int 2000 ;
      n_decode_reencode_selftest ~typ:"int32" ~bytes:4  Fc.Numeric.int32 2000 ;
      n_decode_reencode_selftest ~typ:"int64" ~bytes:8  Fc.Numeric.int64 2000 ;
    ];

    "RNG extraction" >::: [
      random_n_selftest ~typ:"int" Fc.Rng.int 1000 [
        (1, 2); (0, 129); (7, 136); (0, 536870913);
      ] ;
      random_n_selftest ~typ:"int32" Fc.Rng.int32 1000 [
        (7l, 136l); (0l, 536870913l);
      ] ;
      random_n_selftest ~typ:"int64" Fc.Rng.int64 1000 [
        (7L, 136L); (0L, 536870913L); (0L, 2305843009213693953L);
      ] ;
    ] ;

    "XOR" >::: [ xor_selftest 300 ; "example" >::: xor_cases ];

    "B64" >::: [ b64_selftest 300 ; "encoding" >::: b64_enc_cases ; "decoding" >::: b64_dec_cases ];

    "MD5" >::: md5_cases ;

    "SHA1" >::: sha1_cases ;

    "SHA2" >::: sha2_cases ;

    "HMAC" >::: Hmac_tests.hmac_suite ;

    "3DES-ECB" >::: [ ecb_selftest (module Cipher_block.DES.ECB) 100 ] ;

    "3DES-CBC" >::: [ cbc_selftest (module Cipher_block.DES.CBC) 100 ] ;

    "3DES-CTR" >::: Cipher_block.[ ctr_selftest (module DES.CTR) 100;
                                   ctr_offsets  (module DES.CTR) 100; ] ;

    "AES-ECB" >::: [ ecb_selftest (module Cipher_block.AES.ECB) 100
                   ; "SP 300-38A" >::: aes_ecb_cases ] ;

    "AES-CBC" >::: [ cbc_selftest (module Cipher_block.AES.CBC) 100
                   ; "SP 300-38A" >::: aes_cbc_cases ] ;

    "AES-CTR" >::: Cipher_block.[ ctr_selftest (module AES.CTR) 100;
                                  ctr_offsets  (module AES.CTR) 100;
                                  "SP 300-38A" >::: aes_ctr_cases; ] ;

    "AES-GCM" >::: gcm_cases ;

    "AES-CCM" >::: ccm_cases ;
  ]

(*
(* TODO: check numeric extractors. *)
(* e.g. this case backtracks 4 times: *)
  let g = Fortuna.create () in
  Fortuna.reseed ~g Cstruct.(of_string "a") in
  assert_equal ~msg
    Z.(of_string "287217607585902539923938909620913327313")
    (Rng.Z.gen ~g Z.(pow ~$2 128 + ~$1))
*)

(*
  pk_wat:
    ((e 3) (d 24667) (n 37399) (p 149) (q 251) (dp 99) (dq 167) (q' 19))
  x_wat:
    "\000\158"
*)

(*
module CheckGF = struct

  let rec range a b = if a > b then [] else a :: range (a + 1) b

  let rec iterate f a = function 0 -> a | n -> iterate f (f a) (pred n)

  let n_cases f n = List.for_all f @@ range 1 n

  let commutes =
    n_cases @@ fun _ ->
      let (a, b) = I128.(rnd(), rnd()) in GF128.(a + b = b + a)

  let distributes =
    n_cases @@ fun _ ->
      let (a, b, c) = I128.(rnd(), rnd(), rnd()) in
      GF128.((a + b) * c = a * c + b * c)

  let order =
    n_cases @@ fun _ ->
      let a = I128.rnd() in
      a = iterate (fun x -> GF128.(x * x)) a 128
end *)
