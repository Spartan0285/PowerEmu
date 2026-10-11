/* Diagnostic-only, explicitly enabled TCG callback observer. No guest writes. */
#include <qemu-plugin.h>
#include <glib.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;
#define MAX_CPUS 16
#define MAX_SITES 32
#define EVENT_CAPACITY 262144
#define MSR_PR (1U << 14)
typedef struct { uint64_t ns,pc,sp,lr; uint32_t r3,r4,r5,r6,msr,cpu,site,phase; } Event;
_Static_assert(sizeof(Event)==64,"event ABI");
typedef struct { uint64_t pc;uint32_t word,site,phase;bool opcode_match; } Site;
typedef struct {
 Event *events;size_t count;uint64_t drops,register_errors,privileged_skips,identity_skips,window_skips,armed_matches;
 struct qemu_plugin_register *registers[8];GByteArray *scratch;bool supported;
} CPU;
static CPU cpus[MAX_CPUS];static Site sites[MAX_SITES],bad_sites[MAX_SITES];static size_t site_count;
static int cpu_limit;static char *output,*manifest;static atomic_uint_fast64_t word_mismatches,matched_translations,translated_word_mismatches;
static const char *names[8]={"r1","lr","r3","r4","r5","r6","msr","r2"};
#define CHUNK_CAPACITY 16384
#define PENDING_CAPACITY 64
typedef struct { uint64_t ns,entry_ns,sp,lr;uint32_t driver,dest,cpu,entry_cpu;uint64_t serial,reserved;uint8_t pcm[1024]; } Chunk;
_Static_assert(sizeof(Chunk)==1088,"chunk ABI");
typedef struct { atomic_uint state; uint64_t ns,sp,lr,serial;uint32_t driver,dest,cpu; } Pending;
static Pending pending[PENDING_CAPACITY];static Chunk *chunks;static bool produced;
static uint32_t fill_driver,dest_lo,dest_hi,stack_lo,stack_hi;
typedef struct { atomic_uint ready;uint32_t version,toc,driver,dest_lo,dest_hi,stack_lo,stack_hi; } Control;
_Static_assert(sizeof(Control)==32,"control ABI");
static const Control *control;static Control latched;static bool config_latched;
static atomic_uint_fast64_t config_skips,config_errors;
static bool control_gate(void){
 if(!control)return true;
 if(atomic_load_explicit(&control->ready,memory_order_acquire)!=0x50454d31){atomic_fetch_add(&config_skips,1);return false;}
 Control c;memcpy(&c,control,sizeof(c));
 if(atomic_load_explicit(&control->ready,memory_order_acquire)!=0x50454d31){atomic_fetch_add(&config_errors,1);return false;}
 if(config_latched){if(memcmp(&c,&latched,sizeof(c))){atomic_fetch_add(&config_errors,1);return false;}return true;}
 if(c.version!=1||c.toc<4096||c.toc%4||c.driver<4096||c.driver>UINT32_MAX-0x100||c.driver%4||c.dest_lo<4096||c.dest_hi<=c.dest_lo||c.dest_hi-c.dest_lo<1024||c.stack_lo<4096||c.stack_hi<=c.stack_lo||c.stack_hi-c.stack_lo<1024){atomic_fetch_add(&config_errors,1);return false;}
 latched=c;fill_driver=c.driver;dest_lo=c.dest_lo;dest_hi=c.dest_hi;stack_lo=c.stack_lo;stack_hi=c.stack_hi;config_latched=true;return true;
}static atomic_uint_fast64_t chunk_claims,chunk_drops,chunk_reads_failed,pair_failures,pair_serial;
static bool produced_flush_ok=true;
static GByteArray *memory_scratch[MAX_CPUS];
static bool guest_read(unsigned cpu,uint32_t addr,size_t len){
 if(!addr||addr<4096||len>1024||addr>UINT32_MAX-len)return false;
 GByteArray*b=memory_scratch[cpu];g_byte_array_set_size(b,0);
 return qemu_plugin_read_memory_vaddr(addr,b,len)&&b->len==len;
}
static uint64_t now_ns(void);
static atomic_flag capture_guard=ATOMIC_FLAG_INIT;
static void capture_fill_inner(unsigned cpu,const Event*e){
 if(!produced||e->site!=1)return;
 if(e->sp<stack_lo||e->sp>=stack_hi){atomic_fetch_add(&pair_failures,1);return;}
 if(!e->phase){
  if(e->r3!=fill_driver||!guest_read(cpu,e->r3+0xe6,4)){atomic_fetch_add(&pair_failures,1);return;}
  uint8_t*b=memory_scratch[cpu]->data;uint32_t bytes=((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3];
  if(bytes!=1024||e->r4<dest_lo||e->r4>dest_hi-1024){atomic_fetch_add(&pair_failures,1);return;}
  for(unsigned i=0;i<PENDING_CAPACITY;i++){
   unsigned expect=2;if(!atomic_compare_exchange_strong_explicit(&pending[i].state,&expect,3,memory_order_acquire,memory_order_relaxed))continue;
   bool duplicate=(pending[i].sp==e->sp&&pending[i].lr==e->lr)||(e->r4<pending[i].dest+1024&&pending[i].dest<e->r4+1024);atomic_store_explicit(&pending[i].state,2,memory_order_release);
   if(duplicate){atomic_fetch_add(&pair_failures,1);return;}
  }
  for(unsigned i=0;i<PENDING_CAPACITY;i++){
   unsigned expect=0;if(!atomic_compare_exchange_strong(&pending[i].state,&expect,1))continue;
   pending[i].ns=e->ns;pending[i].sp=e->sp;pending[i].lr=e->lr;pending[i].driver=e->r3;pending[i].dest=e->r4;pending[i].cpu=cpu;pending[i].serial=atomic_fetch_add(&pair_serial,1);
   atomic_store_explicit(&pending[i].state,2,memory_order_release);return;
  }
  atomic_fetch_add(&pair_failures,1);return;
 }
 for(unsigned i=0;i<PENDING_CAPACITY;i++){
  unsigned expect=2;if(!atomic_compare_exchange_strong_explicit(&pending[i].state,&expect,3,memory_order_acquire,memory_order_relaxed))continue;
  Pending*p=&pending[i];
  if(p->sp!=e->sp||p->lr!=e->lr){atomic_store_explicit(&p->state,2,memory_order_release);continue;}
  uint64_t n=atomic_fetch_add(&chunk_claims,1);
  if(n>=CHUNK_CAPACITY)atomic_fetch_add(&chunk_drops,1);
  else if(!guest_read(cpu,p->dest,1024))atomic_fetch_add(&chunk_reads_failed,1);
  else {chunks[n]=(Chunk){.ns=e->ns,.entry_ns=p->ns,.sp=e->sp,.lr=e->lr,.driver=p->driver,.dest=p->dest,.cpu=cpu,.entry_cpu=p->cpu,.serial=p->serial};memcpy(chunks[n].pcm,memory_scratch[cpu]->data,1024);chunks[n].reserved=now_ns();}
  atomic_store_explicit(&p->state,0,memory_order_release);return;
 }
 atomic_fetch_add(&pair_failures,1);
}
static void capture_fill(unsigned cpu,const Event*e){
 if(!produced||e->site!=1)return;
 /* Never wait on the diagnostic guard; concurrent execution rejects coverage. */
 if(atomic_flag_test_and_set_explicit(&capture_guard,memory_order_acquire)){atomic_fetch_add(&pair_failures,1);return;}
 capture_fill_inner(cpu,e);atomic_flag_clear_explicit(&capture_guard,memory_order_release);
}
static uint64_t arm_start_ns,arm_end_ns;static atomic_uint required_toc;
static uint64_t now_ns(void){struct timespec ts;if(clock_gettime(CLOCK_MONOTONIC,&ts))return 0;return (uint64_t)ts.tv_sec*1000000000ULL+ts.tv_nsec;}
static bool hex64(const char *s){if(strlen(s)!=64)return false;for(int i=0;i<64;i++)if(!g_ascii_isxdigit(s[i]))return false;return true;}
static bool load_sites(const char *path){
 FILE*f=fopen(path,"r");if(!f)return false;char line[512];bool verified=false;size_t n=0;
 while(fgets(line,sizeof line,f)){
  if(strchr(line,'\n')==NULL&&!feof(f)){fclose(f);return false;}
  line[strcspn(line,"\r\n")]=0;
  if(!strncmp(line,"# verified-source-sha256=",25)){verified=hex64(line+25);continue;}
  if(!line[0]||line[0]=='#')continue;
  unsigned long long pc;unsigned word,id,phase;char extra;
  if(n==MAX_SITES||sscanf(line,"%llx %x %u %u %c",&pc,&word,&id,&phase,&extra)!=4||
     pc%4||pc>UINT32_MAX||!pc||phase>1||id>=MAX_SITES){fclose(f);return false;}
  for(size_t j=0;j<n;j++)if(sites[j].pc==pc){fclose(f);return false;}
  sites[n]=(Site){pc,word,id,phase,true};bad_sites[n]=(Site){pc,word,id,phase,false};n++;
 }
 bool ok=!ferror(f)&&verified&&n;fclose(f);if(ok)site_count=n;return ok;
}
static void cpu_init(qemu_plugin_id_t id,unsigned index){
 if(index>=(unsigned)cpu_limit)return;CPU*c=&cpus[index];
 GArray*a=qemu_plugin_get_registers();
 for(guint i=0;a&&i<a->len;i++){
  qemu_plugin_reg_descriptor*r=&g_array_index(a,qemu_plugin_reg_descriptor,i);
  for(int j=0;j<8;j++)if(!strcmp(r->name,names[j]))c->registers[j]=r->handle;
 }
 if(a)g_array_free(a,true);c->supported=true;
 for(int j=0;j<8;j++)if(!c->registers[j])c->supported=false;
 /* Allocate/page-touch before execution; register reads append <=8 bytes. */
 if(produced){memory_scratch[index]=g_byte_array_sized_new(1024);g_byte_array_set_size(memory_scratch[index],1024);memset(memory_scratch[index]->data,0,1024);g_byte_array_set_size(memory_scratch[index],0);}
 c->scratch=g_byte_array_sized_new(64);g_byte_array_set_size(c->scratch,64);memset(c->scratch->data,0,64);g_byte_array_set_size(c->scratch,0);
}
static bool read_reg(CPU*c,int n,uint64_t*value){
 g_byte_array_set_size(c->scratch,0);int bytes=qemu_plugin_read_register(c->registers[n],c->scratch);
 if((bytes!=4&&bytes!=8)||c->scratch->len!=(guint)bytes)return false;
 uint64_t v=0;for(int j=0;j<bytes;j++)v=(v<<8)|c->scratch->data[j];*value=v;return true;
}
static void observe(unsigned index,void*opaque){
 if(index>=(unsigned)cpu_limit)return;CPU*c=&cpus[index];Site*s=opaque;
 uint64_t ns=now_ns();if(!ns){c->register_errors++;return;}
 if(ns<arm_start_ns||ns>=arm_end_ns){c->window_skips++;return;}
 if(control){
  if(atomic_flag_test_and_set_explicit(&capture_guard,memory_order_acquire)){atomic_fetch_add(&config_errors,1);return;}
  bool valid=control_gate();if(valid)required_toc=latched.toc;atomic_flag_clear_explicit(&capture_guard,memory_order_release);if(!valid)return;
 }
 if(!c->supported){c->register_errors++;return;}
 uint64_t msr,toc;if(!read_reg(c,6,&msr)||!read_reg(c,7,&toc)){c->register_errors++;return;}
 if(!(msr&MSR_PR)){c->privileged_skips++;return;}
 if(toc!=required_toc){c->identity_skips++;return;}
 if(!s->opcode_match){atomic_fetch_add(&word_mismatches,1);return;}
 c->armed_matches++;
 if(c->count==EVENT_CAPACITY){c->drops++;return;}
 uint64_t r[6];for(int j=0;j<6;j++)if(!read_reg(c,j,&r[j])){c->register_errors++;return;}
 c->events[c->count++]=(Event){.ns=ns,.pc=s->pc,.sp=r[0],.lr=r[1],.r3=r[2],.r4=r[3],.r5=r[4],.r6=r[5],.msr=msr,.cpu=index,.site=s->site,.phase=s->phase};
 capture_fill(index,&c->events[c->count-1]);
}
static void translate(qemu_plugin_id_t id,struct qemu_plugin_tb*tb){
 for(size_t j=0;j<qemu_plugin_tb_n_insns(tb);j++){
  struct qemu_plugin_insn*insn=qemu_plugin_tb_get_insn(tb,j);uint64_t pc=qemu_plugin_insn_vaddr(insn);
  for(size_t k=0;k<site_count;k++)if(pc==sites[k].pc){
   uint8_t bytes[4];bool good=qemu_plugin_insn_size(insn)==4&&qemu_plugin_insn_data(insn,bytes,4)==4;
   uint32_t word=good?((uint32_t)bytes[0]<<24)|((uint32_t)bytes[1]<<16)|((uint32_t)bytes[2]<<8)|bytes[3]:0;
   good=good&&word==sites[k].word;
   if(!good)atomic_fetch_add(&translated_word_mismatches,1);
   /* Register both outcomes: a boot TB may remain cached after arming. */
   qemu_plugin_register_vcpu_insn_exec_cb(insn,observe,QEMU_PLUGIN_CB_R_REGS,good?&sites[k]:&bad_sites[k]);
   if(good)atomic_fetch_add(&matched_translations,1);
  }
 }
}
static void finish(qemu_plugin_id_t id,void*p){
 if(produced){
  uint64_t n=atomic_load(&chunk_claims),unfinished=0;for(unsigned i=0;i<PENDING_CAPACITY;i++)if(atomic_load(&pending[i].state))unfinished++;
  char*p=g_strdup_printf("%s.chunks",output);FILE*f=fopen(p,"wb");bool ok=f!=NULL;if(f){size_t retained=MIN(n,CHUNK_CAPACITY);if(fwrite(chunks,sizeof(Chunk),retained,f)!=retained)ok=false;if(fclose(f))ok=false;}g_free(p);
  p=g_strdup_printf("%s.chunks.json",output);f=fopen(p,"w");if(f){fprintf(f,"{\"clock\":\"CLOCK_MONOTONIC\",\"record_bytes\":%zu,\"records\":%llu,\"capacity\":%u,\"read_errors\":%llu,\"drops\":%llu,\"pair_failures\":%llu,\"unfinished\":%llu,\"driver\":%u,\"dest_lo\":%u,\"dest_hi\":%u,\"stack_lo\":%u,\"stack_hi\":%u,\"output_format_verified\":false,\"flush_ok\":%s}\n",sizeof(Chunk),(unsigned long long)MIN(n,CHUNK_CAPACITY),CHUNK_CAPACITY,(unsigned long long)atomic_load(&chunk_reads_failed),(unsigned long long)atomic_load(&chunk_drops),(unsigned long long)atomic_load(&pair_failures),(unsigned long long)unfinished,fill_driver,dest_lo,dest_hi,stack_lo,stack_hi,ok?"true":"false");bool bad=ferror(f);if(fclose(f))bad=true;if(bad)ok=false;}else ok=false;produced_flush_ok=ok;g_free(p);
  char*cfg=g_strdup_printf("%s.config.json",output);FILE*cf=fopen(cfg,"w");if(cf){fprintf(cf,"{\"control_mode\":%s,\"latched\":%s,\"config_skips\":%llu,\"config_errors\":%llu,\"version\":%u,\"toc\":%u,\"driver\":%u,\"dest_lo\":%u,\"dest_hi\":%u,\"stack_lo\":%u,\"stack_hi\":%u}\n",control?"true":"false",config_latched?"true":"false",(unsigned long long)atomic_load(&config_skips),(unsigned long long)atomic_load(&config_errors),latched.version,required_toc,fill_driver,dest_lo,dest_hi,stack_lo,stack_hi);bool bad=ferror(cf);if(fclose(cf))bad=true;if(bad)produced_flush_ok=false;}else produced_flush_ok=false;g_free(cfg);if(control)munmap((void*)control,sizeof(Control));
  for(int i=0;i<cpu_limit;i++)if(memory_scratch[i])g_byte_array_unref(memory_scratch[i]);free(chunks);
 }
 char*path=g_strdup_printf("%s.events",output);FILE*f=fopen(path,"wb");bool ok=f!=NULL;
 if(f){for(int i=0;i<cpu_limit;i++)if(fwrite(cpus[i].events,sizeof(Event),cpus[i].count,f)!=cpus[i].count)ok=false;if(fclose(f))ok=false;}
 g_free(path);path=g_strdup_printf("%s.json",output);f=fopen(path,"w");
 if(f){fprintf(f,"{\"record_bytes\":%zu,\"clock\":\"CLOCK_MONOTONIC\",\"events_order\":\"grouped by CPU; sort by ns\",\"flush_ok\":%s,\"word_mismatches\":%llu,\"matched_translations\":%llu,\"translated_word_mismatches_all_time\":%llu,\"arm_start_ns\":%llu,\"arm_end_ns\":%llu,\"required_toc\":%u,\"event_capacity_per_cpu\":%u,\"cpu\":[",sizeof(Event),ok?"true":"false",(unsigned long long)atomic_load(&word_mismatches),(unsigned long long)atomic_load(&matched_translations),(unsigned long long)atomic_load(&translated_word_mismatches),(unsigned long long)arm_start_ns,(unsigned long long)arm_end_ns,required_toc,EVENT_CAPACITY);
  /* Window and identity values are emitted before the CPU array in the header below. */
  for(int i=0;i<cpu_limit;i++)fprintf(f,"%s{\"id\":%d,\"supported\":%s,\"records\":%zu,\"drops\":%llu,\"register_errors\":%llu,\"privileged_skips\":%llu,\"identity_skips\":%llu,\"window_skips\":%llu,\"armed_matches\":%llu}",i?",":"",i,cpus[i].supported?"true":"false",cpus[i].count,(unsigned long long)cpus[i].drops,(unsigned long long)cpus[i].register_errors,(unsigned long long)cpus[i].privileged_skips,(unsigned long long)cpus[i].identity_skips,(unsigned long long)cpus[i].window_skips,(unsigned long long)cpus[i].armed_matches);
  fputs("]}\n",f);bool bad=ferror(f);if(fclose(f))bad=true;if(bad)ok=false;
 }
 if(produced){g_free(path);path=g_strdup_printf("%s.produced-flush.json",output);FILE*done=fopen(path,"w");if(done){fprintf(done,"{\"all_outputs_ok\":%s}\n",produced_flush_ok&&ok?"true":"false");if(fclose(done))fprintf(stderr,"Produced final receipt flush failed\n");}else fprintf(stderr,"Produced final receipt open failed\n");}
 g_free(path);for(int i=0;i<cpu_limit;i++){free(cpus[i].events);if(cpus[i].scratch)g_byte_array_unref(cpus[i].scratch);}g_free(output);g_free(manifest);
}
QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,const qemu_info_t*info,int argc,char**argv){
 bool enabled=false;const char*out=NULL,*input=NULL,*control_path=NULL;unsigned delay=0,window=0;uint32_t toc=0;bool have_delay=false;
 for(int i=0;i<argc;i++){
  if(!strcmp(argv[i],"enabled=1"))enabled=true;
  else if(!strncmp(argv[i],"out=",4))out=argv[i]+4;
  else if(!strncmp(argv[i],"sites=",6))input=argv[i]+6;
  else if(!strncmp(argv[i],"arm-after-sec=",14)){char*end;errno=0;unsigned long v=strtoul(argv[i]+14,&end,10);if(errno||end==argv[i]+14||*end||v>600)return -1;delay=v;have_delay=true;}
  else if(!strncmp(argv[i],"window-sec=",11)){char*end;errno=0;unsigned long v=strtoul(argv[i]+11,&end,10);if(errno||end==argv[i]+11||*end||v<1||v>120)return -1;window=v;}
  else if(!strncmp(argv[i],"toc=",4)){char*end;errno=0;unsigned long v=strtoul(argv[i]+4,&end,16);if(errno||end==argv[i]+4||*end||v<4096||v>UINT32_MAX||v%4)return -1;toc=v;}
  else if(!strncmp(argv[i],"control=",8))control_path=argv[i]+8;
  else if(!strcmp(argv[i],"produced-chunks=1"))produced=true;
  else if(!strncmp(argv[i],"dest-range=",11)||!strncmp(argv[i],"stack-range=",12)){
   bool dest=!strncmp(argv[i],"dest-range=",11);char*start=argv[i]+(dest?11:12),*end;errno=0;unsigned long lo=strtoul(start,&end,16);if(errno||end==start||*end!=':'||lo<4096||lo>UINT32_MAX)return -1;start=end+1;unsigned long hi=strtoul(start,&end,16);if(errno||end==start||*end||hi>UINT32_MAX||hi<=lo||hi-lo<1024)return -1;
   if(dest){dest_lo=lo;dest_hi=hi;}else{stack_lo=lo;stack_hi=hi;}
  }
  else if(!strncmp(argv[i],"fill-driver=",12)){char*end;errno=0;unsigned long v=strtoul(argv[i]+12,&end,16);if(errno||end==argv[i]+12||*end||v<4096||v>UINT32_MAX-0x100||v%4)return -1;fill_driver=v;}
  else return -1;
 }
 if(!enabled)return 0;
 if(!have_delay||!window||(!toc&&!control_path)||(produced&&!control_path&&(!fill_driver||!dest_lo||!stack_lo)))return -1;
 uint64_t install_ns=now_ns();if(!install_ns)return -1;arm_start_ns=install_ns+(uint64_t)delay*1000000000ULL;arm_end_ns=arm_start_ns+(uint64_t)window*1000000000ULL;required_toc=toc;
 if(!info->system_emulation||strncmp(info->target_name,"ppc",3)||!out||out[0]!='/'||!input||input[0]!='/'||info->system.max_vcpus<1||info->system.max_vcpus>MAX_CPUS||!load_sites(input))return -1;
 if(control_path){
  if(!produced||control_path[0]!='/')return -1;int fd=open(control_path,O_RDONLY|O_NOFOLLOW);if(fd<0)return -1;struct stat st;
  if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&0777)!=0600||st.st_size!=sizeof(Control)){close(fd);return -1;}
  void*m=mmap(NULL,sizeof(Control),PROT_READ,MAP_SHARED,fd,0);close(fd);if(m==MAP_FAILED)return -1;control=m;
  if(atomic_load(&control->ready)!=0){munmap(m,sizeof(Control));control=NULL;return -1;}
 }
 if(produced){bool entry=false,ret=false;for(size_t i=0;i<site_count;i++)if(sites[i].site==1){if(sites[i].phase)ret=true;else entry=true;}if(!entry||!ret)return -1;chunks=calloc(CHUNK_CAPACITY,sizeof(Chunk));if(!chunks)return -1;volatile unsigned char*b=(void*)chunks;for(size_t i=0;i<CHUNK_CAPACITY*sizeof(Chunk);i+=4096)b[i]=0;}
 cpu_limit=info->system.max_vcpus;output=g_strdup(out);manifest=g_strdup(input);
 for(int i=0;i<cpu_limit;i++){cpus[i].events=calloc(EVENT_CAPACITY,sizeof(Event));if(!cpus[i].events)return -1;/* calloc may be lazy: force every page resident. */volatile unsigned char*b=(void*)cpus[i].events;for(size_t j=0;j<EVENT_CAPACITY*sizeof(Event);j+=4096)b[j]=0;}
 qemu_plugin_register_vcpu_init_cb(id,cpu_init);qemu_plugin_register_vcpu_tb_trans_cb(id,translate);qemu_plugin_register_atexit_cb(id,finish,NULL);return 0;
}
