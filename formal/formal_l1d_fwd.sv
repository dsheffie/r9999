/* formal_l1d_fwd.sv -- formally prove the L1D store->load FORWARD DATA PATH is
 * byte-exact for EVERY memory op (aligned SB/SH/SW/SD/SC/SCD, unaligned
 * SWL/SWR/SDL/SDR stores; LB/LBU/LH/LHU/LW/LWU/LD/LL/LLD aligned + LWL/LWR/LDL/LDR
 * unaligned loads) at every offset.  Data-path half of the store->load-forward
 * audit: proves, for a store that a load forwards from, the load's bytes match a
 * plain big-endian byte memory (+ the destination reg's old value, for unaligned
 * loads).  Does NOT model the forward CONTROL (when/which store fires).
 *
 * Method (mirrors formal/run_decode_formal.sh): merge/select/bswap logic copied
 * VERBATIM from l1d.sv (16B line: 128b, addr[3:2] word off, addr[3] dword off);
 * an INDEPENDENT 16-byte oracle mb[k]=cl[8k +:8] (big-endian, address order)
 * applies the same store then reads the same load; `bad`=(RTL != oracle) proven
 * UNSAT by yosys `sat`.  Covers full AND partial overlap (oracle inits from cl).
 */
module formal_l1d_fwd
  (
   input logic [127:0] cl,        // symbolic starting cache line (internal repr)
   input logic [63:0]  st_data,   // symbolic store data (rt)
   input logic [63:0]  ld_rt_old, // dest reg old value (unaligned loads merge it)
   input logic [4:0]   st_op,
   input logic [3:0]   st_off,     // store byte offset within the 16B line
   input logic [4:0]   ld_op,
   input logic [3:0]   ld_off,     // load byte offset within the 16B line
   output logic        bad,        // must be UNSAT
   output logic        active      // property applicable (must be reachable)
   );

   // ---- op encodings (machine.vh) ----
   localparam [4:0] MEM_LB=0, MEM_LBU=1, MEM_LH=2, MEM_LHU=3, MEM_LW=4;
   localparam [4:0] MEM_SB=5, MEM_SH=6, MEM_SW=7, MEM_SWR=8, MEM_SWL=9;
   localparam [4:0] MEM_LWR=10, MEM_LWL=11, MEM_SC=12, MEM_LD=14, MEM_SD=15;
   localparam [4:0] MEM_LWU=16, MEM_LDL=17, MEM_LDR=18, MEM_SDL=19, MEM_SDR=20;
   localparam [4:0] MEM_LL=21, MEM_LLD=22, MEM_SCD=23;

   // ---- helpers copied VERBATIM from l1d.sv / machine.vh (BIG_ENDIAN branch) ----
   function logic [31:0] bswap32(logic [31:0] in);
      return {in[7:0], in[15:8], in[23:16], in[31:24]};
   endfunction
   function logic [15:0] bswap16(logic [15:0] in);
      return {in[7:0], in[15:8]};
   endfunction
   function logic sext16(logic [15:0] in);
      return in[7];   // BIG_ENDIAN branch (machine.vh)
   endfunction
   function logic [63:0] bswap64(logic [63:0] x);
      return {x[7:0],x[15:8],x[23:16],x[31:24],x[39:32],x[47:40],x[55:48],x[63:56]};
   endfunction
   function logic [127:0] merge_cl32(logic [127:0] c, logic [31:0] w32, logic [1:0] pos);
      logic [127:0] o;
      case(pos)
	2'd0: o = {c[127:32], w32};
	2'd1: o = {c[127:64], w32, c[31:0]};
	2'd2: o = {c[127:96], w32, c[63:0]};
	2'd3: o = {w32, c[95:0]};
      endcase
      return o;
   endfunction
   function logic [31:0] select_cl32(logic [127:0] c, logic [1:0] pos);
      logic [31:0] w;
      case(pos)
	2'd0: w = c[31:0];
	2'd1: w = c[63:32];
	2'd2: w = c[95:64];
	2'd3: w = c[127:96];
      endcase
      return w;
   endfunction
   function logic [127:0] merge_cl64(logic [127:0] c, logic [63:0] w64, logic pos);
      logic [127:0] o;
      case(pos)
	1'd0: o = {c[127:64], w64};
	1'd1: o = {w64, c[63:0]};
      endcase
      return o;
   endfunction
   function logic [63:0] select_cl64(logic [127:0] c, logic pos);
      logic [63:0] w;
      case(pos)
	1'd0: w = c[63:0];
	1'd1: w = c[127:64];
      endcase
      return w;
   endfunction

   wire [1:0] st_word = st_off[3:2];
   wire       st_dw   = st_off[3];
   wire [1:0] ld_word = ld_off[3:2];
   wire       ld_dw   = ld_off[3];

   // =====================================================================
   //  RTL store-merge -> forwarded line `fline`  (verbatim l1d.sv)
   // =====================================================================
   logic [31:0]  st_w32, st_bw32;
   logic [63:0]  st_dword, st_merged;
   logic [127:0] fline;
   always_comb
     begin
	st_w32   = select_cl32(cl, st_word);
	st_bw32  = bswap32(st_w32);
	st_dword = bswap64(select_cl64(cl, st_dw));
	st_merged = 64'd0;
	fline = cl;
	case(st_op)
	  MEM_SB:
	    case(st_off[1:0])
	      2'd0: fline = merge_cl32(cl, {st_w32[31:8], st_data[7:0]}, st_word);
	      2'd1: fline = merge_cl32(cl, {st_w32[31:16], st_data[7:0], st_w32[7:0]}, st_word);
	      2'd2: fline = merge_cl32(cl, {st_w32[31:24], st_data[7:0], st_w32[15:0]}, st_word);
	      2'd3: fline = merge_cl32(cl, {st_data[7:0], st_w32[23:0]}, st_word);
	    endcase
	  MEM_SH:
	    case(st_off[1])
	      1'b0: fline = merge_cl32(cl, {st_w32[31:16], bswap16(st_data[15:0])}, st_word);
	      1'b1: fline = merge_cl32(cl, {bswap16(st_data[15:0]), st_w32[15:0]}, st_word);
	    endcase
	  MEM_SW, MEM_SC:
	    fline = merge_cl32(cl, bswap32(st_data[31:0]), st_word);
	  MEM_SD, MEM_SCD:
	    fline = merge_cl64(cl, bswap64(st_data[63:0]), st_dw);
	  MEM_SWR:
	    case(st_off[1:0])
	      2'd0: fline = merge_cl32(cl, bswap32({st_data[7:0],  st_bw32[23:0]}), st_word);
	      2'd1: fline = merge_cl32(cl, bswap32({st_data[15:0], st_bw32[15:0]}), st_word);
	      2'd2: fline = merge_cl32(cl, bswap32({st_data[23:0], st_bw32[7:0]}),  st_word);
	      2'd3: fline = merge_cl32(cl, bswap32(st_data[31:0]), st_word);
	    endcase
	  MEM_SWL:
	    case(st_off[1:0])
	      2'd0: fline = merge_cl32(cl, bswap32(st_data[31:0]), st_word);
	      2'd1: fline = merge_cl32(cl, bswap32({st_bw32[31:24], st_data[31:8]}),  st_word);
	      2'd2: fline = merge_cl32(cl, bswap32({st_bw32[31:16], st_data[31:16]}), st_word);
	      2'd3: fline = merge_cl32(cl, bswap32({st_bw32[31:8],  st_data[31:24]}), st_word);
	    endcase
	  MEM_SDL:
	    begin
	       case(st_off[2:0])
		 3'd0: st_merged = st_data;
		 3'd1: st_merged = {st_dword[63:56], st_data[63:8]};
		 3'd2: st_merged = {st_dword[63:48], st_data[63:16]};
		 3'd3: st_merged = {st_dword[63:40], st_data[63:24]};
		 3'd4: st_merged = {st_dword[63:32], st_data[63:32]};
		 3'd5: st_merged = {st_dword[63:24], st_data[63:40]};
		 3'd6: st_merged = {st_dword[63:16], st_data[63:48]};
		 3'd7: st_merged = {st_dword[63:8],  st_data[63:56]};
	       endcase
	       fline = merge_cl64(cl, bswap64(st_merged), st_dw);
	    end
	  MEM_SDR:
	    begin
	       case(st_off[2:0])
		 3'd0: st_merged = {st_data[7:0],  st_dword[55:0]};
		 3'd1: st_merged = {st_data[15:0], st_dword[47:0]};
		 3'd2: st_merged = {st_data[23:0], st_dword[39:0]};
		 3'd3: st_merged = {st_data[31:0], st_dword[31:0]};
		 3'd4: st_merged = {st_data[39:0], st_dword[23:0]};
		 3'd5: st_merged = {st_data[47:0], st_dword[15:0]};
		 3'd6: st_merged = {st_data[55:0], st_dword[7:0]};
		 3'd7: st_merged = st_data;
	       endcase
	       fline = merge_cl64(cl, bswap64(st_merged), st_dw);
	    end
	  default: fline = cl;
	endcase
     end

   // =====================================================================
   //  RTL load-extract from `fline`  (verbatim l1d.sv; data = ld_rt_old)
   // =====================================================================
   logic [31:0] ld_w32, ld_bw32;
   logic [63:0] ld_dword, ld_res;
   always_comb
     begin
	ld_w32   = select_cl32(fline, ld_word);
	ld_bw32  = bswap32(ld_w32);
	ld_dword = bswap64(select_cl64(fline, ld_dw));
	ld_res = 64'd0;
	case(ld_op)
	  MEM_LB:
	    case(ld_off[1:0])
	      2'd0: ld_res = {{56{ld_w32[7]}},  ld_w32[7:0]};
	      2'd1: ld_res = {{56{ld_w32[15]}}, ld_w32[15:8]};
	      2'd2: ld_res = {{56{ld_w32[23]}}, ld_w32[23:16]};
	      2'd3: ld_res = {{56{ld_w32[31]}}, ld_w32[31:24]};
	    endcase
	  MEM_LBU:
	    case(ld_off[1:0])
	      2'd0: ld_res = {56'd0, ld_w32[7:0]};
	      2'd1: ld_res = {56'd0, ld_w32[15:8]};
	      2'd2: ld_res = {56'd0, ld_w32[23:16]};
	      2'd3: ld_res = {56'd0, ld_w32[31:24]};
	    endcase
	  MEM_LH:
	    case(ld_off[1])
	      1'b0: ld_res = {{48{sext16(ld_w32[15:0])}},  bswap16(ld_w32[15:0])};
	      1'b1: ld_res = {{48{sext16(ld_w32[31:16])}}, bswap16(ld_w32[31:16])};
	    endcase
	  MEM_LHU:
	    ld_res = {48'd0, bswap16(ld_off[1] ? ld_w32[31:16] : ld_w32[15:0])};
	  MEM_LW, MEM_LL:
	    ld_res = {{32{ld_bw32[31]}}, ld_bw32};
	  MEM_LWU:
	    ld_res = {32'd0, ld_bw32};
	  MEM_LD, MEM_LLD:
	    ld_res = bswap64(select_cl64(fline, ld_dw));
	  MEM_LWR:
	    case(ld_off[1:0])
	      2'd0: ld_res = {{32{ld_rt_old[31]}}, ld_rt_old[31:8],  ld_bw32[31:24]};
	      2'd1: ld_res = {{32{ld_rt_old[31]}}, ld_rt_old[31:16], ld_bw32[31:16]};
	      2'd2: ld_res = {{32{ld_rt_old[31]}}, ld_rt_old[31:24], ld_bw32[31:8]};
	      2'd3: ld_res = {{32{ld_bw32[31]}}, ld_bw32};
	    endcase
	  MEM_LWL:
	    case(ld_off[1:0])
	      2'd0: ld_res = {{32{ld_bw32[31]}}, ld_bw32};
	      2'd1: ld_res = {{32{ld_bw32[23]}}, ld_bw32[23:0], ld_rt_old[7:0]};
	      2'd2: ld_res = {{32{ld_bw32[15]}}, ld_bw32[15:0], ld_rt_old[15:0]};
	      2'd3: ld_res = {{32{ld_bw32[7]}},  ld_bw32[7:0],  ld_rt_old[23:0]};
	    endcase
	  MEM_LDL:
	    case(ld_off[2:0])
	      3'd0: ld_res = ld_dword;
	      3'd1: ld_res = {ld_dword[55:0], ld_rt_old[7:0]};
	      3'd2: ld_res = {ld_dword[47:0], ld_rt_old[15:0]};
	      3'd3: ld_res = {ld_dword[39:0], ld_rt_old[23:0]};
	      3'd4: ld_res = {ld_dword[31:0], ld_rt_old[31:0]};
	      3'd5: ld_res = {ld_dword[23:0], ld_rt_old[39:0]};
	      3'd6: ld_res = {ld_dword[15:0], ld_rt_old[47:0]};
	      3'd7: ld_res = {ld_dword[7:0],  ld_rt_old[55:0]};
	    endcase
	  MEM_LDR:
	    case(ld_off[2:0])
	      3'd0: ld_res = {ld_rt_old[63:8],  ld_dword[63:56]};
	      3'd1: ld_res = {ld_rt_old[63:16], ld_dword[63:48]};
	      3'd2: ld_res = {ld_rt_old[63:24], ld_dword[63:40]};
	      3'd3: ld_res = {ld_rt_old[63:32], ld_dword[63:32]};
	      3'd4: ld_res = {ld_rt_old[63:40], ld_dword[63:24]};
	      3'd5: ld_res = {ld_rt_old[63:48], ld_dword[63:16]};
	      3'd6: ld_res = {ld_rt_old[63:56], ld_dword[63:8]};
	      3'd7: ld_res = ld_dword;
	    endcase
	  default: ld_res = 64'd0;
	endcase
     end

   // =====================================================================
   //  INDEPENDENT ORACLE: 16-byte big-endian memory mb[k]=cl[8k +:8]
   // =====================================================================
   integer     i, j;
   logic [7:0] mb [0:15];   // architectural byte at line offset k (post-store)
   logic [3:0] k3, k7;      // in-word / in-dword offset for unaligned
   always_comb
     begin
	for(i=0;i<16;i=i+1)
	  begin
	     mb[i] = cl[ (i<<3) +: 8 ];   // init from cl (address-order bytes)
	  end
	k3 = {2'd0, st_off[1:0]};
	k7 = {1'd0, st_off[2:0]};
	// ---- apply store (big-endian) ----
	case(st_op)
	  MEM_SB: mb[st_off] = st_data[7:0];
	  MEM_SH: begin mb[st_off]=st_data[15:8]; mb[st_off+4'd1]=st_data[7:0]; end
	  MEM_SW, MEM_SC:
	    for(i=0;i<4;i=i+1) mb[st_off+i[3:0]] = st_data[ ((3-i)<<3) +: 8 ];
	  MEM_SD, MEM_SCD:
	    for(i=0;i<8;i=i+1) mb[st_off+i[3:0]] = st_data[ ((7-i)<<3) +: 8 ];
	  MEM_SWL:                                 // MS (4-k3) bytes -> [off .. word_end]
	    for(i=0;i<4;i=i+1) if(i <= (3-k3)) mb[st_off+i[3:0]] = st_data[ ((3-i)<<3) +: 8 ];
	  MEM_SWR:                                 // LS (k3+1) bytes -> [word_base .. off]
	    for(j=0;j<4;j=j+1) if(j <= k3)     mb[st_off-j[3:0]] = st_data[ (j<<3) +: 8 ];
	  MEM_SDL:                                 // MS (8-k7) bytes -> [off .. dword_end]
	    for(i=0;i<8;i=i+1) if(i <= (7-k7)) mb[st_off+i[3:0]] = st_data[ ((7-i)<<3) +: 8 ];
	  MEM_SDR:                                 // LS (k7+1) bytes -> [dword_base .. off]
	    for(j=0;j<8;j=j+1) if(j <= k7)     mb[st_off-j[3:0]] = st_data[ (j<<3) +: 8 ];
	  default: ;
	endcase
     end

   // ---- read the load from mb (+ rt_old merge for unaligned) ----
   logic [3:0]  lk3, lk7;
   logic [31:0] o32;
   logic [63:0] o64, oracle_res;
   always_comb
     begin
	lk3 = {2'd0, ld_off[1:0]};
	lk7 = {1'd0, ld_off[2:0]};
	o32 = ld_rt_old[31:0];
	o64 = ld_rt_old;
	oracle_res = 64'd0;
	case(ld_op)
	  MEM_LB:  oracle_res = {{56{mb[ld_off][7]}}, mb[ld_off]};
	  MEM_LBU: oracle_res = {56'd0, mb[ld_off]};
	  MEM_LH:  oracle_res = {{48{mb[ld_off][7]}}, mb[ld_off], mb[ld_off+4'd1]};
	  MEM_LHU: oracle_res = {48'd0, mb[ld_off], mb[ld_off+4'd1]};
	  MEM_LW, MEM_LL:
	    begin
	       o32 = {mb[ld_off], mb[ld_off+4'd1], mb[ld_off+4'd2], mb[ld_off+4'd3]};
	       oracle_res = {{32{o32[31]}}, o32};
	    end
	  MEM_LWU:
	    begin
	       o32 = {mb[ld_off], mb[ld_off+4'd1], mb[ld_off+4'd2], mb[ld_off+4'd3]};
	       oracle_res = {32'd0, o32};
	    end
	  MEM_LD, MEM_LLD:
	    begin
	       o64 = {mb[ld_off],      mb[ld_off+4'd1], mb[ld_off+4'd2], mb[ld_off+4'd3],
		      mb[ld_off+4'd4], mb[ld_off+4'd5], mb[ld_off+4'd6], mb[ld_off+4'd7]};
	       oracle_res = o64;
	    end
	  MEM_LWL:                    // MS (4-lk3) bytes into result high, rt_old low kept
	    begin
	       o32 = ld_rt_old[31:0];
	       for(i=0;i<4;i=i+1) if(i <= (3-lk3)) o32[ ((3-i)<<3) +: 8 ] = mb[ld_off+i[3:0]];
	       oracle_res = {{32{o32[31]}}, o32};
	    end
	  MEM_LWR:                    // LS (lk3+1) bytes into result low, rt_old high kept
	    begin
	       o32 = ld_rt_old[31:0];
	       for(j=0;j<4;j=j+1) if(j <= lk3) o32[ (j<<3) +: 8 ] = mb[ld_off-j[3:0]];
	       oracle_res = {{32{o32[31]}}, o32};
	    end
	  MEM_LDL:
	    begin
	       o64 = ld_rt_old;
	       for(i=0;i<8;i=i+1) if(i <= (7-lk7)) o64[ ((7-i)<<3) +: 8 ] = mb[ld_off+i[3:0]];
	       oracle_res = o64;
	    end
	  MEM_LDR:
	    begin
	       o64 = ld_rt_old;
	       for(j=0;j<8;j=j+1) if(j <= lk7) o64[ (j<<3) +: 8 ] = mb[ld_off-j[3:0]];
	       oracle_res = o64;
	    end
	  default: oracle_res = 64'd0;
	endcase
     end

   // =====================================================================
   //  property scope + assertion
   // =====================================================================
   wire w_st_valid = (st_op==MEM_SB)||(st_op==MEM_SH)||(st_op==MEM_SW)||(st_op==MEM_SD)||
		     (st_op==MEM_SC)||(st_op==MEM_SCD)||(st_op==MEM_SWL)||(st_op==MEM_SWR)||
		     (st_op==MEM_SDL)||(st_op==MEM_SDR);
   wire w_ld_valid = (ld_op==MEM_LB)||(ld_op==MEM_LBU)||(ld_op==MEM_LH)||(ld_op==MEM_LHU)||
		     (ld_op==MEM_LW)||(ld_op==MEM_LWU)||(ld_op==MEM_LD)||(ld_op==MEM_LL)||
		     (ld_op==MEM_LLD)||(ld_op==MEM_LWL)||(ld_op==MEM_LWR)||
		     (ld_op==MEM_LDL)||(ld_op==MEM_LDR);
   // aligned ops must be naturally aligned (unaligned ops accept any offset)
   wire w_st_aligned = (st_op==MEM_SH)             ? (st_off[0]==1'b0)   :
		       (st_op==MEM_SW||st_op==MEM_SC) ? (st_off[1:0]==2'd0) :
		       (st_op==MEM_SD||st_op==MEM_SCD)? (st_off[2:0]==3'd0) : 1'b1;
   wire w_ld_aligned = (ld_op==MEM_LH||ld_op==MEM_LHU)                 ? (ld_off[0]==1'b0)   :
		       (ld_op==MEM_LW||ld_op==MEM_LWU||ld_op==MEM_LL) ? (ld_off[1:0]==2'd0) :
		       (ld_op==MEM_LD||ld_op==MEM_LLD)                ? (ld_off[2:0]==3'd0) : 1'b1;

   assign active = w_st_valid && w_ld_valid && w_st_aligned && w_ld_aligned;
   assign bad    = active && (ld_res != oracle_res);

endmodule
