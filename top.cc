#include "top.hh"
#include "sgi_indy.hh"

#define BRANCH_DEBUG 1
#define CACHE_STATS 1


bool globals::enClockFuncts = false;
uint64_t globals::icountMIPS = 0;
uint64_t globals::cycle = 0;
bool globals::trace_retirement = false;
bool globals::trace_fp = false;


static state_t *s = nullptr;
static state_t *ss = nullptr;
static uint64_t insns_retired = 0;
static uint64_t pipestart = 0, pipeend = ~(0UL);
static pipeline_logger *pl = nullptr;
static uint64_t l1d_misses = 0, l1d_insns = 0;
static uint64_t last_retire_cycle = 0, last_retire_pc  = 0;

static std::map<uint64_t, uint64_t> retire_map;

static uint64_t n_fetch[5] = {0};
static uint64_t n_resteer_bubble = 0;
static uint64_t n_fq_full = 0;

static uint64_t n_uq_full[3] = {0};
static uint64_t n_alloc[3] = {0};
static uint64_t n_rdy[3] = {0};

static uint64_t n_int_exec[2] = {0};
static uint64_t n_mem_exec[3] = {0};

static uint64_t q_full[3] = {0};
static uint64_t dq_empty =  0;
static uint64_t uq_full = 0;
static uint64_t n_active = 0;
static uint64_t rob_full = 0;

static uint64_t l1d_reqs = 0;
static uint64_t l1d_acks = 0;
static uint64_t l1d_stores = 0;

static std::map<int,uint64_t> block_distribution;
static std::map<int,uint64_t> restart_distribution;
static std::map<int,uint64_t> restart_ds_distribution;
static std::map<int,uint64_t> fault_distribution;
static std::map<int,uint64_t> branch_distribution;
static std::map<int,uint64_t> fault_to_restart_distribution;

static const char* l1d_stall_str[8] =
  {
   "no stall", //0
   "got miss", //1 
   "full memory queue", //2
   "not possible", //3
   "load retry", //4
   "store to same set", //5
   "cm block stall", //6
   "inflight rob ptr", //7
};
static uint64_t l1d_stall_reasons[8] = {0};

static bool pending_fault = false;
static uint64_t fault_start_cycle = 0;

void record_branches(int n_branches) {
  branch_distribution[n_branches]++;
}

void record_faults(int n_faults) {
  fault_distribution[n_faults]++;
  if(n_faults && not(pending_fault)) {
    pending_fault = true;
    fault_start_cycle = globals::cycle;
  }
}

void record_restart(int cycles) {
  restart_distribution[cycles]++;
  pending_fault = false;

  fault_to_restart_distribution[(globals::cycle - fault_start_cycle)]++;
  fault_start_cycle = 0;
  //std::cout << "clearing fault took "
  //<< (globals::cycle - fault_start_cycle)
  //<< " cycles\n";
}

void record_ds_restart(int cycles) {
  restart_ds_distribution[cycles]++;
}


void record_l1d(int req, int ack, int ack_st, int blocked, int stall_reason) {
  l1d_reqs += req;
  l1d_acks += ack;
  l1d_stores += ack_st;
  block_distribution[__builtin_popcount(blocked)]++;
  l1d_stall_reasons[stall_reason&15]++;
}

static std::map<int, uint64_t> int_sched_rdy_map;

void report_exec(int int_valid, int int_ready,
		 int mem_valid, int mem_ready,
		 int fp_valid,  int fp_ready,
		 int intq_full, int memq_full,
		 int fpq_full,
		 int blocked_by_store,
		 int ready_int) {
  n_int_exec[0] += int_valid;
  n_int_exec[1] += int_ready;
  n_mem_exec[0] += mem_valid;
  n_mem_exec[1] += mem_ready;
  n_mem_exec[2] += blocked_by_store;
    
  q_full[0] += intq_full;
  q_full[1] += memq_full;
  q_full[2] += fpq_full;
  
  int_sched_rdy_map[__builtin_popcount(ready_int)]++;
}


void record_alloc(int rf,
		  int a1, int a2, int de,
		  int f1, int f2,
		  int r1, int r2, int active) {

  rob_full += rf;
  dq_empty += de;
  uq_full += f1;
  n_active += active;
  
  if(a2)
    ++n_alloc[2];
  else if(a1)
    ++n_alloc[1];
  else
    ++n_alloc[0];

  if(f2)
    ++n_uq_full[2];
  else if(f1)
    ++n_uq_full[1];
  else
    ++n_uq_full[0];
  
  if(r2)
    ++n_rdy[2];
  else if(r1)
    ++n_rdy[1];
  else
    ++n_rdy[0];
  
}


void record_fetch(int p1, int p2, int p3, int p4, 
		  long long pc1, long long pc2, long long pc3, long long pc4,
		  int bubble, int fq_full) {
  n_resteer_bubble += bubble;
  n_fq_full += fq_full;


  if(p1)
    ++n_fetch[1];
  else if(p2)
    ++n_fetch[2];
  else if(p3)
    ++n_fetch[3];
  else if(p4)
    ++n_fetch[4];
  else
    ++n_fetch[0];
}

static std::map<int, uint64_t> mem_lat_map, fp_lat_map, non_mem_lat_map;

int check_insn_bytes(long long pc, int data) {
  uint32_t insn = get_insn(pc, s);
  return (*reinterpret_cast<uint32_t*>(&data)) == insn;
}

static long long lrc = -1;
static uint64_t record_insns_retired = 0;

void record_retirement(long long pc, long long fetch_cycle, long long alloc_cycle, long long complete_cycle, long long retire_cycle,
		       int faulted , int is_mem, int is_fp, int missed_l1d) {

  //if(pc == 0x2033c || pc == 0x20340 || pc == 0x20344 || pc == 0x20348) {
  //auto i = getAsmString(get_insn(pc, s), pc);
  //std::cout << std::hex << pc << std::dec << " " << i << " : " << alloc_cycle << "," << complete_cycle << "," << retire_cycle << "," << faulted << "\n";
  //}
  uint32_t insn = get_insn(pc, s);
  uint64_t delta = retire_cycle - last_retire_cycle;

  if(retire_cycle < lrc) {
    std::cout << "retirement cycle out-of-order\n";
    exit(-1);
  }
  lrc = retire_cycle;
  
  if(is_mem) {
    //auto i = getAsmString(insn, pc);
    //std::cout << std::hex << pc << std::dec << " " << i << " : " << alloc_cycle << ","
    //<< complete_cycle << "," << retire_cycle << "," << faulted << "\n";
    //std::cout << std::hex << pc << std::dec << " " << i << " : "
    mem_lat_map[(complete_cycle-alloc_cycle)]++;
    //<< (complete_cycle-alloc_cycle) << "\n";    
  }
  else if(is_fp) {
    fp_lat_map[(complete_cycle-alloc_cycle)]++;
  }
  else {
    non_mem_lat_map[(complete_cycle-alloc_cycle)]++;
  }
  //if(delta == 3) {
  //std::cout << "curr = " << std::hex << pc << std::dec << " : " << getAsmString(get_insn(pc, s), pc) << "\n";
  //std::cout << "last = " << std::hex << last_retire_pc << std::dec << " : " << getAsmString(get_insn(last_retire_pc, s), last_retire_pc) << "\n";
  //}
  //std::cout << "delta = " << delta << "\n";
  retire_map[delta]++;
  
  last_retire_cycle = retire_cycle;
  last_retire_pc = pc;
  
  if(missed_l1d) {
    //std::cout << "pc = " << std::hex << pc << " missed cache " << std::dec
    //<< " : " << getAsmString(get_insn(pc, s), pc)
    //<< "\n";
    ++l1d_misses;
  }
  l1d_insns += is_mem;
  
  if((pl != nullptr) and (record_insns_retired >= pipestart) and (record_insns_retired < pipeend)) {
    pl->append(record_insns_retired, getAsmString(get_insn(pc, s), pc), pc, fetch_cycle, alloc_cycle, complete_cycle, retire_cycle, faulted);
  }
  ++record_insns_retired;
}



int main(int argc, char **argv) {
  static_assert(sizeof(itype) == 4, "itype must be 4 bytes");
  //std::fesetround(FE_TOWARDZERO);
  namespace po = boost::program_options; 
  // Initialize Verilators variables
  bool enable_checker = true;
  std::string pipelog;
  std::string mips_binary = "dhrystone3";
  std::string log_name = "log.txt";
  std::string pushout_name = "pushout.txt";
  std::string branch_name = "branch_info.txt";
  bool sgi_indy = false;
  uint64_t heartbeat = 1UL<<36, start_trace_at = ~0UL;
  uint64_t max_cycle = 0, max_icnt = 0, mem_lat = 2;
  uint64_t last_store_addr = 0, last_load_addr = 0, last_addr = 0;
  int misses_inflight = 0;
  std::map<uint64_t, uint64_t> pushout_histo;
  int64_t mem_reply_cycle = -1L;
  try {
    po::options_description desc("Options");
    desc.add_options() 
      ("help", "Print help messages")
      ("checker,c", po::value<bool>(&enable_checker)->default_value(true), "use checker")
      ("file,f", po::value<std::string>(&mips_binary), "mips binary")
      ("heartbeat,h", po::value<uint64_t>(&heartbeat)->default_value(1<<24), "heartbeat for stats")
      ("log,l", po::value<std::string>(&log_name), "stats log filename")
      ("pushout", po::value<std::string>(&pushout_name), "pushout log filename")
      ("branch", po::value<std::string>(&branch_name), "branch log filename")
      ("memlat,m", po::value<uint64_t>(&mem_lat)->default_value(4), "memory latency")
      ("pipelog,p", po::value<std::string>(&pipelog), "log for pipeline tracing")
      ("pipestart", po::value<uint64_t>(&pipestart)->default_value(0), "when to start logging")
      ("pipeend", po::value<uint64_t>(&pipeend)->default_value(~0UL), "when to stop logging")      
      ("maxcycle", po::value<uint64_t>(&max_cycle)->default_value(1UL<<34), "maximum cycles")
      ("maxicnt", po::value<uint64_t>(&max_icnt)->default_value(1UL<<50), "maximum icnt")
      ("tracefp", po::value<bool>(&globals::trace_fp)->default_value(false), "trace fp instructions")
      ("trace,t", po::value<bool>(&globals::trace_retirement)->default_value(false), "trace retired instruction stream")
      ("starttrace,s", po::value<uint64_t>(&start_trace_at)->default_value(~0UL), "start tracing retired instructions")
      ("indy", po::value<bool>(&sgi_indy)->default_value(false), "sgi indy")
      ; 
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm); 
  }
  catch(po::error &e) {
    std::cerr <<"command-line error : " << e.what() << "\n";
    return -1;
  }
  uint32_t max_insns_per_cycle = 4;
  uint32_t max_insns_per_cycle_hist_sz = 2*max_insns_per_cycle;

  std::map<uint32_t, uint64_t> mispredicts;

  uint64_t hist = 0, spec_hist = 0;
  static const int TBL_SIZE = (1<<24);
  static const int BTB_SIZE = (1<<6);
  
  
  uint64_t inflight[32] = {0};
  uint64_t *insns_delivered = new uint64_t[max_insns_per_cycle_hist_sz];
  memset(insns_delivered, 0, sizeof(uint64_t)*max_insns_per_cycle_hist_sz);
  
  uint32_t max_inflight = 0;


  const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
  contextp->commandArgs(argc, argv);  
  //contextp->traceEverOn(true);
  
  sparse_mem *sm0 = new sparse_mem();
  sparse_mem *sm1 = new sparse_mem();
  s = new state_t(*sm0);
  ss = new state_t(*sm1);
  initState(s);
  initState(ss);
  initCapstone();

  if(not(sgi_indy)) {
    if(mips_binary.empty()) {
      std::cout << "no elf binary\n";
      exit(-1);
    }
    load_elf(mips_binary.c_str(), s);
    load_elf(mips_binary.c_str(), ss);
  }


  if(sgi_indy){
    struct stat st;
    int rc;
    int fd = open("ip24prom.070-9101-005.bin", O_RDONLY);
    if(fd<0) {
      printf("INTERP: open() returned %d\n", fd);
      exit(-1);
    }
    rc = fstat(fd,&st);
    if(rc<0) {
      printf("INTERP: fstat() returned %d\n", rc);
      exit(-1);
    }
    char *buf = (char*)mmap(nullptr, st.st_size,
                            PROT_READ, MAP_PRIVATE, fd, 0);

    memcpy(s->mem.mem +(0xbfc00000 & 0x1fffffff), buf, st.st_size);
    memcpy(ss->mem.mem +(0xbfc00000 & 0x1fffffff), buf, st.st_size);    

    s->pc = 0xbfc00000;

    close(fd);
  }

  
  // Create an instance of our module under test
   //Vcore_l1d_l1i *tb = new Vcore_l1d_l1i;
  std::unique_ptr<Vcore_l1d_l1i> tb(new Vcore_l1d_l1i);
  uint32_t last_match_pc = 0;
  uint64_t last_retire = 0, last_check = 0, last_restart = 0;
  uint64_t last_retired_pc = 0, last_retired_fp_pc = 0;
  uint64_t mismatches = 0, n_stores = 0, n_loads = 0;
  uint64_t n_branches = 0, n_mispredicts = 0, n_checks = 0, n_flush_cycles = 0;
  bool got_mem_req = false, got_mem_rsp = false, incorrect = false, got_putchar = false;
  //assert reset
  tb->retire_allowed = 1;
  tb->mem_rsp_bad = 0;
  for(globals::cycle = 0; (globals::cycle < 4) && !Verilated::gotFinish(); ++globals::cycle) {
    contextp->timeInc(1);  // 1 timeprecision period passes...
    tb->mem_rsp_valid = 0;
    tb->reset = 1;
    tb->extern_irq = 0;
    tb->clk = 1;
    tb->eval();
    tb->clk = 0;
    tb->eval();
    ++globals::cycle;
  }
  
  tb->resume_pc = s->pc;
  contextp->timeInc(1);  // 1 timeprecision period passes...  
  tb->reset = 0;
  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();


  while(!tb->ready_for_resume) {
    ++globals::cycle;  
    tb->clk = 1;
    tb->eval();
    tb->clk = 0;
    tb->eval();
  }
  
  ++globals::cycle;
  tb->resume = 1;

  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();
  
  ++globals::cycle;  
  tb->resume = 0;
  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();


  if(not(pipelog.empty())) {
    pl = new pipeline_logger(pipelog);
  }
  
    
  ++globals::cycle;
  tb->resume = 1;
  tb->resume_pc = s->pc;
  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();
  ++globals::cycle;  
  tb->resume = 0;
  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();
  //done with initialize
  globals::cycle = 0;  

  
  double t0 = timestamp();
  while(!Verilated::gotFinish() && (globals::cycle < max_cycle) && (insns_retired < max_icnt)) {
    contextp->timeInc(1);  // 1 timeprecision periodd passes...    

    tb->clk = 1;
    tb->eval();

    if(not(tb->putchar_fifo_empty)) {
      std::cout << tb->putchar_fifo_out;
      got_putchar = true;
      tb->putchar_fifo_pop = 1;
    }
    
    
    if(tb->retire_reg_valid) {
      s->gpr[tb->retire_reg_ptr] = tb->retire_reg_data;
      //if(tb->retire_reg_ptr == R_a0) {
      //std::cout << std::hex << "insn with pc " << tb->retire_pc << " updates a0 \n"
      //<< std::dec;
      //}      
    }

    // if(tb->retire_valid) {
    //   std::cout << std::hex
    // 		<< tb->retire_pc
    // 		<< std::dec
    // 		<< "\n";
    // }
    
    
#ifdef BRANCH_DEBUG
    if(tb->branch_pc_valid) {
      ++n_branches;
    }
    if(tb->branch_fault) {
      mispredicts[tb->branch_pc]++; 
    }
    if(tb->branch_fault) {
      ++n_mispredicts;
    }
#endif
    if(tb->in_flush_mode) {
      ++n_flush_cycles;
    }

    //if(tb->extern_irq) {
    //tb->extern_irq = 0;
    //}
    
    //if((globals::cycle & ((1UL<<8)-1)) == 0) {
    //std::cout << "firing irq at cycle " << globals::cycle << "\n";
    //tb->extern_irq = 1;
    //}
    
    
    if(tb->retire_valid) {
      ++insns_retired;
      if(last_retire > 1) {
	pushout_histo[tb->retire_pc] += last_retire;
      }
      last_retire = 0;

      last_retired_pc = tb->retire_pc;

      if(insns_retired >= start_trace_at)
	globals::trace_retirement = true;


      
      if(((insns_retired % heartbeat) == 0) or globals::trace_retirement ) {
	//uint32_t r_inst = s->mem.get<uint32_t>(tb->retire_pc);
	//r_inst = bswap<IS_LITTLE_ENDIAN>(r_inst);	
	std::cout << "retiring "
		  << std::hex
		  << tb->retire_pc
		  << std::dec
		  << " cycle " << globals::cycle
		  << " "  <<  getAsmString(get_insn(tb->retire_pc&0x1fffffff, s), tb->retire_pc&0x1fffffff)	  
		  << std::fixed
		  << ", " << static_cast<double>(insns_retired) / globals::cycle << " IPC "
		  << ", insns_retired "
		  << insns_retired
		  << ", mispredict pki "
		  << (static_cast<double>(n_mispredicts) / insns_retired) * 1000.0
		  << std::defaultfloat	  
		  <<" \n";
      }
      if(tb->retire_two_valid) {
	++insns_retired;
	if(((insns_retired % heartbeat) == 0) or globals::trace_retirement ) {
	  std::cout << "retiring "
		    << std::hex
		    << tb->retire_two_pc
		    << std::dec
		    << " cycle " << globals::cycle
		    << " "  <<  getAsmString(get_insn(tb->retire_two_pc&0x1fffffff, s), tb->retire_two_pc&0x1fffffff)	  	    
		    << std::fixed
		    << ", " << static_cast<double>(insns_retired) / globals::cycle << " IPC "	    
		    << ", insns_retired "
		    << insns_retired
		    << ", mispredict pki "
		    << (static_cast<double>(n_mispredicts) / insns_retired) * 1000.0
		    << std::defaultfloat
		    <<" \n";
	}
      }
      if(tb->got_bad_addr) {
	std::cout << "fatal - unaligned address\n";
	break;
      }
       
      
      if( enable_checker) {
	//std::cout << std::hex << tb->retire_pc << "," << ss->pc << std::dec << "\n";	  	
	if(tb->retire_pc == ss->pc) {
	  //std::cout << std::hex << tb->retire_pc << "," << ss->pc << std::dec << "\n";	  	
	  execMips(ss);
	  // if(static_cast<uint32_t>(ss->mem.at(0x4cadc)) == 3) {
	  //   std::cout << "changed memory at " << std::hex << ss->pc << std::dec << "\n";
	  //   exit(-1);
	  // }
	  
	  bool diverged = false;
	  if(ss->pc == (tb->retire_pc + 4)) {
	    for(int i = 0; i < 32; i++) {
	      if((ss->gpr[i] != s->gpr[i])) {
		int wrong_bits = __builtin_popcount(ss->gpr[i] ^ s->gpr[i]);
		++mismatches;
		std::cout << "register " << getGPRName(i)
			  << " does not match : rtl "
			  << std::hex
			  << s->gpr[i]
			  << " simulator "
			  << ss->gpr[i]
			  << std::dec
			  << " bits in difference "
			  << wrong_bits
			  << "\n";
		//globals::trace_retirement |= (wrong_bits != 0);
		diverged = true;//(wrong_bits > 16);
		uint32_t r_inst = s->mem.get<uint32_t>(ss->pc);
		r_inst = bswap<IS_LITTLE_ENDIAN>(r_inst);
		std::cout << "incorrect "
			  << std::hex
			  << ss->pc 
			  << std::dec
			  << " : " << getAsmString(r_inst, ss->pc )
			  << "\n";
		
	      }
	    }

	    
	  }
	  
	  if(diverged) {
	    incorrect = true;
	    uint32_t r_inst = s->mem.get<uint32_t>(tb->retire_pc);
	    r_inst = bswap<IS_LITTLE_ENDIAN>(r_inst);
	    std::cout << "incorrect "
		      << std::hex
		      << tb->retire_pc
		      << std::dec
		      << " : " << getAsmString(r_inst, tb->retire_pc)
		      << "\n";
	    for(int i = 0; i < 32; i+=4) {
	      std::cout << "reg "
			<< getGPRName(i)
			<< " = "
			<< std::hex
			<< s->gpr[i]
			<< " reg "
			<< getGPRName(i+1)
			<< " = "
			<< s->gpr[i+1]
			<< " reg "
			<< getGPRName(i+2)
			<< " = "
			<< s->gpr[i+2]
			<< " reg "
			<< getGPRName(i+3)
			<< " = "
			<< s->gpr[i+3]
			<< std::dec <<"\n";
	    }
	    break;
	  }


	  
	  ++n_checks;
	  last_check = 0;
	  last_match_pc =  tb->retire_pc; 
	}
	else {
	  ++last_check;
	  if(last_check > 2) {
	    uint32_t linsn = bswap<IS_LITTLE_ENDIAN>(s->mem.get<uint32_t>(last_match_pc));
	    std::cerr << "no match in a while, last match : "
		      << std::hex
		      << last_match_pc
		      << " "
		      << getAsmString(linsn, last_match_pc)
		      << ", rtl pc =" << tb->retire_pc
		      << ", sim pc =" << ss->pc
		      << std::dec
		      <<"\n";
	    for(int i = 0; i < 32; i+=4) {
	      std::cout << "reg "
			<< getGPRName(i)
			<< " = "
			<< std::hex
			<< s->gpr[i]
			<< " reg "
			<< getGPRName(i+1)
			<< " = "
			<< s->gpr[i+1]
			<< " reg "
			<< getGPRName(i+2)
			<< " = "
			<< s->gpr[i+2]
			<< " reg "
			<< getGPRName(i+3)
			<< " = "
			<< s->gpr[i+3]
			<< std::dec <<"\n";
	    }
	    break;
	  }
	}
      }
      //do       
    }
    
    if(tb->retire_reg_two_valid) {
      s->gpr[tb->retire_reg_two_ptr] = tb->retire_reg_two_data;
      //if(tb->retire_reg_two_ptr == R_a0) {
      //std::cout << std::hex << "insn two with pc " << tb->retire_two_pc << " updates a0 \n"
      //<< std::dec;
      //}
    }
    

    if(enable_checker && tb->retire_two_valid) {
      if(tb->retire_two_pc == ss->pc) {
	execMips(ss);
	++n_checks;
	last_check = 0;
	last_match_pc =  tb->retire_two_pc; 
      }
    }

    
    ++last_retire;
    if(last_retire > (1U<<16) && not(tb->in_flush_mode)) {
      std::cout << "in flush mode = " << static_cast<int>(tb->in_flush_mode) << "\n";
      std::cerr << "no retire in " << last_retire << " cycles, last retired "
    		<< std::hex
    		<< last_retired_pc + 0
    		<< std::dec
    		<< " "
    		<< getAsmString(get_insn(last_retired_pc+0, s), last_retired_pc+0)
    		<< "\n";
      break;
    }
    if(tb->got_break) {
      std::cout << "got break, epc = " << std::hex << tb->epc << std::dec << "\n";      
      break;
    }
    else if(tb->got_ud) {
      std::cerr << "GOT UD for "
		<< std::hex
		<< tb->epc
		<< std::dec
		<< " "
		<< getAsmString(get_insn(tb->retire_pc&0x1fffffff, s), tb->retire_pc&0x1fffffff)
		<< "\n";
      break;
    }
    else if(tb->got_bad_addr) {
      std::cerr << "GOT BAD VA for "
		<< std::hex
		<< tb->epc
		<< std::dec
		<< " "
		<< getAsmString(get_insn(tb->epc, s), tb->epc)
		<< "\n";
      break;
    }
    inflight[tb->inflight & 31]++;
    max_inflight = std::max(max_inflight, static_cast<uint32_t>(tb->inflight));

    //negedge
    tb->mem_rsp_valid = 0;

    if(tb->mem_req_valid && (mem_reply_cycle == -1)) {
      
      mem_reply_cycle = globals::cycle + (tb->mem_req_opcode == 4 ? 1 : 2)*mem_lat;
      
    }
    
    if(/*tb->mem_req_valid*/mem_reply_cycle ==globals::cycle) {
      //std::cout << "got memory request for address "
      //<< std::hex << tb->mem_req_addr << std::dec <<"\n";
      last_retire = 0;
      mem_reply_cycle = -1;
      assert(tb->mem_req_valid);

      if(sgi_indy) {
	mem_range_t mr = compute_mem_range_type(tb->mem_req_addr);
	std::cout << "fetch to " << mr << "\n";
      }
      
      if(tb->mem_req_opcode == 4) {/*load word */
	//printf("--> ld mask %x\n", tb->mem_req_mask);
	uint16_t m = tb->mem_req_mask;

	
	for(int i = 0, k = 0; i < 4; i++) {
	  uint64_t ea = (tb->mem_req_addr + 4*i) & ((1UL<<32)-1);

	  uint32_t d = 0;
	  for(int j = 0; j < 4; j++) {
	    if( ((m >> k) & 1) ) {
	      uint32_t by = s->mem.get<uint8_t>(ea+j);
	      d |= (by << (j*8));
	      //printf("read byte %lx : %x\n", ea+j, by);
	    }
	    k++;
	  }
	  if(sgi_indy) {
	    if(compute_mem_range_type(ea) != mem_range_t::boot_rom) {
	      //std::cout << "attempting to access " << compute_mem_range_type(ea)
	      //<< " : "
	      //<< std::hex <<  ea << std::dec << "\n";
	      //exit(-1);
	    }
	  }
	  tb->mem_rsp_load_data[i] = d;//s->mem.get<uint32_t>(ea);
	  //std::cout << "\tloading " << std::hex << ea << " with data "
	  //<< bswap<false>(s->mem.get<uint32_t>(ea))
	  //<< std::dec << "\n";
	}
	last_load_addr = tb->mem_req_addr;
	assert((tb->mem_req_addr & 0xf) == 0);
	++n_loads;
      }
      else if(tb->mem_req_opcode == 7) { /* store word */
	uint16_t m = tb->mem_req_mask;
	//if(m != static_cast<uint16_t>(~0)) {
	//printf("store for address %x has mask %x\n", tb->mem_req_addr, tb->mem_req_mask);
	//}
	//printf("store mask %x\n", m);
	for(int i = 0, k = 0; i < 4; i++) {
	  uint32_t d = tb->mem_req_store_data[i];
	  uint64_t ea = (tb->mem_req_addr + 4*i) & ((1UL<<32)-1);
	  for(int j = 0; j < 4; j++) {
	    if(((m >> k) & 1)) {
	      uint32_t by = (d>>(8*j)) & 0xff;	      
	      //printf("write byte %x to address %lx\n", by, ea+j);
	      s->mem.set<uint8_t>(ea+j, by);
	    }
	    k++;
	  }
	}
	last_store_addr = tb->mem_req_addr;
	++n_stores;
      }
      last_addr = tb->mem_req_addr;
      tb->mem_rsp_valid = 1;
    }

    
    tb->clk = 0;
    tb->eval();
    if(got_mem_req) {
      got_mem_req = false;
    }
    if(got_mem_rsp) {
      tb->mem_rsp_valid = 0;
      got_mem_rsp = false;
    }
    if(got_putchar) {
      tb->putchar_fifo_pop = 0;
      got_putchar = false;
    }    
    ++globals::cycle;
  }
  tb->final();
  t0 = timestamp() - t0;

  if(incorrect) {
    s->mem.compare(ss->mem);
  }
  
  if(!incorrect) {
    std::ofstream out(log_name);
    out << "n_mispredicts = " << n_mispredicts
	<<  ", cycles = " << globals::cycle
	<< ", insns = " << insns_retired
	<< ", n_checks = " << n_checks
	<< "\n";
    out << static_cast<double>(insns_retired) / globals::cycle << " insn per cycle\n";
    double avg_inflight = 0, sum = 0;
    for(int i = 0; i < 32; i++) {
      if(inflight[i] == 0) continue;
      avg_inflight += i * inflight[i];
      sum += inflight[i];
      //printf("inflight[%d] = %lu\n", i, inflight[i]);
    }
    avg_inflight /= sum;
    out << insns_retired << " insns retired\n";

  
    out << "avg insns in ROB = " << avg_inflight
	      << ", max inflight = " << max_inflight << "\n";
  

    out << "l1d cache hits = " << tb->l1d_cache_hits << "\n";
    out << "l1d cache accesses = " << tb->l1d_cache_accesses << "\n";
    out << "l1d hit rate = "
	      << 100.0 *(static_cast<double>(tb->l1d_cache_hits) / tb->l1d_cache_accesses)
	      << "\n";
    out << "l1i cache hits = " << tb->l1i_cache_hits << "\n";
    out << "l1i cache accesses = " << tb->l1i_cache_accesses << "\n";
    out << "l1i hit rate = "
	      << 100.0 *(static_cast<double>(tb->l1i_cache_hits) / tb->l1i_cache_accesses)
	      << "\n";

    out << "l2 cache hits = " << tb->l2_cache_hits << "\n";
    out << "l2 cache accesses = " << tb->l2_cache_accesses << "\n";


    out << "branch mispredict rate = "
	      << (static_cast<double>(n_mispredicts)/n_branches)*100.0
	      << "\n";

    out << "mispredicts per kiloinsn = "
	      << (static_cast<double>(n_mispredicts) / insns_retired) * 1000.0
	      << "\n";
    out << n_flush_cycles << " cycles spent flushing caches\n";
    out << n_loads << " cache line loads\n";
    out << n_stores << " cache line stores\n";
    out << l1d_misses << " l1d misses\n";
    out << l1d_insns << " insns access the l1d\n";

    uint64_t total_fetch = 0, total_fetch_cycles = 0;
    for(int i = 0; i < 5; i++) {
      //out << "n_fetch[" << i << "] = " << n_fetch[i] << "\n";
      total_fetch_cycles += n_fetch[i];
      total_fetch += n_fetch[i] * i;
    }
    out << "avg fetch = " << static_cast<double>(total_fetch) / total_fetch_cycles << "\n";
    out << "resteer bubble = " << n_resteer_bubble << "\n";
    out << "front-end queues full = " << n_fq_full << "\n";
    double total_fetch_cap = 0.0;

  
    // for(int i = 0; i < 3; i++) {
    //   out << "uq_full[" << i << "] = " << n_uq_full[i] << "\n";
    // }
    // for(int i = 0; i < 3; i++) {
    //   out << "alloc[" << i << "] = " << n_alloc[i] << "\n";
    // }
    out << n_int_exec[0] << " cycles where int exec queue is not empty\n";
    out << n_int_exec[1] << " cycles where int exec queue dispatches\n";
    out << n_mem_exec[0] << " cycles where mem exec queue is not empty\n";
    out << n_mem_exec[1] << " cycles where mem exec queue dispatches\n";
    out << n_mem_exec[2] << " cycles where mem exec queue is blocked by a store\n";

    out << q_full[0] << " cycles with int queue full\n";
    out << q_full[1] << " cycles with mem queue full\n";
    out << dq_empty  << " cycles with an empty decode queue\n";
    out << uq_full   << " cycles with a  full uop queue\n";
    out << n_active << " cycles where the machine is in active state\n";
    out << rob_full << " cycles where the rob is full\n";
  
    //for(int i = 0; i < 3; i++) {
    //out << "insn ready " << i
    //		<< " "
    //<< n_rdy[i] << "\n";
    //}
    double avg_restart = 0.0;
    uint64_t total_restart = 0, accum_restart = 0;
    for(auto &p : restart_distribution) {
      avg_restart += (p.first * p.second);
      total_restart += p.second;
    }
    for(auto &p : restart_distribution) {
      accum_restart += p.second;
      if(accum_restart >= (total_restart/2)) {
	out << p.first << " median flush cycles\n";
	break;
      }
    }
    if(total_restart != 0) {
      out << avg_restart << " cycles spent in pipeline flush\n";
      avg_restart /= total_restart;
      out << total_restart << " times pipeline was flushed\n";
      out << avg_restart << " cycles to flush on avg\n";
      out << restart_distribution.begin()->first << " min cycles to flush\n";
      out << restart_distribution.rbegin()->first << " max cycles to flush\n";
    }
    
    double avg_ds_restart = 0.0;
    uint64_t total_ds_restart = 0, accum_ds_restart = 0;
    for(auto &p : restart_ds_distribution) {
      avg_ds_restart += (p.first * p.second);
      total_ds_restart += p.second;
    }
    for(auto &p : restart_ds_distribution) {
      accum_ds_restart += p.second;
      if(accum_ds_restart >= (total_ds_restart/2)) {
	out << p.first << " median delay slot flush cycles\n";
	break;
      }
    }
    if(total_ds_restart != 0) {
      out << avg_ds_restart << " cycles spent waiting for delay slot in flush\n";
      avg_ds_restart /= total_ds_restart;
      out << avg_ds_restart << " cycles waiting on delay slot on avg\n";
      out << restart_ds_distribution.begin()->first << " min cycles for delay slot\n";
      out << restart_ds_distribution.rbegin()->first << " max cycles for delay slot\n";
    }
    for(auto &p : fault_distribution) {
      out << p.first << " faults inflight, " << p.second << " times\n";
    }
    for(auto &p : branch_distribution) {
      out << p.first << " branches inflight, " << p.second << " times\n";
    }
    for(auto &p : fault_to_restart_distribution) {
      out << p.first << " cycles before restart, " << p.second << " times\n";
    }
    dump_histo(branch_name, mispredicts, s);
    uint64_t total_pushout = 0;
    for(auto &p : pushout_histo) {
      total_pushout += p.second;
    }
    out << total_pushout << " cycles of pushout\n";
    dump_histo(pushout_name, pushout_histo, s);

    //std::ofstream branch_info("retire_info.csv");
    uint64_t total_retire = 0, total_cycle = 0;
    for(auto &p : retire_map) {
      total_retire += p.second;
    }
    for(auto &p : retire_map) {
      //branch_info << p.first << "," << p.second << "," << static_cast<double>(p.second) / total_retire << "\n";
      total_cycle += (p.first * p.second);
    }
    //branch_info.close();
    int median_int_rdy;
    double avg_int_rdy = histo_mean_median(int_sched_rdy_map, median_int_rdy);
    out << "avg int rdy insn = " << avg_int_rdy << "\n";
    out << "median int rdy insn = " << median_int_rdy << "\n";
    
    int median_mem_lat = 0;
    double avg_mem_lat = histo_mean_median(mem_lat_map, median_mem_lat);
    out << "avg mem alloc to complete = " << avg_mem_lat << "\n";
    out << "median mem alloc to complete = " << median_mem_lat << "\n";

    avg_mem_lat = histo_mean_median(non_mem_lat_map, median_mem_lat);
    out << "avg non-mem alloc to complete = " << avg_mem_lat << "\n";
    out << "median non-mem alloc to complete = " << median_mem_lat << "\n";

    
    out << "l1d_reqs = " << l1d_reqs << "\n";
    out << "l1d_acks = " << l1d_acks << "\n";
    out << "l1d_stores = " << l1d_stores << "\n";
    out << "l1d tput = " << (static_cast<double>(l1d_acks) /l1d_reqs) << "\n";
    
    //for(auto &p :block_distribution) {
    //out << p.first << "," << p.second << "\n";
    //}
    for(int i = 1; i < 8; i++) {
      if(l1d_stall_reasons[i] != 0) {
	out << l1d_stall_reasons[i] << " " << l1d_stall_str[i] << "\n";
      }
    }
    std::cout << "total_retire = " << total_retire << "\n";
    std::cout << "total_cycle  = " << total_cycle << "\n";
    std::cout << "total ipc    = " << static_cast<double>(total_retire) / total_cycle << "\n";

    uint64_t total_histo = 0;
    for(auto &p : ss->insn_histo) {
      if(p.second) {
	out << p.first << "," << p.second << "\n";
	total_histo += p.second;
      }
    }
    out << "total_histo = " << total_histo << "\n";
    out.close();
  }
  else {
    std::cout << "instructions retired = " << insns_retired << "\n";
  }
  
  std::cout << "simulation took " << t0 << " seconds, " << (insns_retired/t0)
	    << " insns per second\n";


  delete s;
  delete ss;
  delete [] insns_delivered;
  if(pl) {
    delete pl;
  }
  //delete tb;
  stopCapstone();
  exit(EXIT_SUCCESS);
}
